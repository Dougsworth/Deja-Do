import AppKit
import ApplicationServices
import ScreenCaptureKit
import Vision
import DejaDoCore

/// Looks at the screen itself: grabs a window's pixels with ScreenCaptureKit
/// and reads its text with Apple's Vision framework. Used for apps that don't
/// describe their buttons through Accessibility, and for checking steps.
/// Nothing captured here leaves the Mac.
enum ScreenVision {
    static var hasPermission: Bool { CGPreflightScreenCaptureAccess() }

    static func requestPermission() { _ = CGRequestScreenCaptureAccess() }

    static func openSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }

    /// A window as pixels and text, in window points from its top left.
    struct WindowRead {
        /// Greyscale, one pixel per point.
        let image: GrayImage
        let lines: [OCRLine]

        var thumbnail: GrayImage { image.resized(width: 64, height: 40) }
    }

    /// Captures a window's area of the screen and optionally reads its text.
    /// Deja Do's own windows are left out of the picture.
    static func read(windowFrame wf: CGRect, ocr: Bool, fast: Bool = false) async -> WindowRead? {
        guard wf.width >= 4, wf.height >= 4, let captured = await capture(wf) else { return nil }
        let (cg, shown) = captured
        let size = CGSize(width: shown.width, height: shown.height)
        var gray = Self.gray(cg, width: Int(size.width.rounded()), height: Int(size.height.rounded()))
        var lines = ocr ? readText(cg, pointSize: size, fast: fast) : []

        // Part of the window was off screen: put what we have where it belongs.
        let dx = shown.minX - wf.minX, dy = shown.minY - wf.minY
        if dx > 0.5 || dy > 0.5 || shown.width < wf.width - 0.5 || shown.height < wf.height - 0.5 {
            var full = GrayImage(width: Int(wf.width.rounded()), height: Int(wf.height.rounded()), fill: UInt8(gray.mean.rounded()))
            let ox = Int(dx.rounded()), oy = Int(dy.rounded())
            for y in 0..<gray.height where y + oy < full.height {
                for x in 0..<gray.width where x + ox < full.width { full[x + ox, y + oy] = gray[x, y] }
            }
            gray = full
            lines = lines.map { OCRLine(text: $0.text, frame: $0.frame.offsetBy(dx: dx, dy: dy), confidence: $0.confidence) }
        }
        return WindowRead(image: gray, lines: lines)
    }

    /// Pixels of a rectangle of the screen, in global points with the origin
    /// at the top left of the main display, the same space Accessibility uses.
    /// Returns the image and the part of the rectangle it actually covers.
    static func capture(_ rect: CGRect) async -> (CGImage, CGRect)? {
        guard hasPermission else { return nil }
        guard #available(macOS 14.0, *) else { return nil }
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            let center = CGPoint(x: rect.midX, y: rect.midY)
            guard let display = content.displays.first(where: { CGDisplayBounds($0.displayID).contains(center) })
                    ?? content.displays.first else { return nil }
            let bounds = CGDisplayBounds(display.displayID)
            let shown = rect.intersection(bounds)
            guard !shown.isNull, shown.width >= 1, shown.height >= 1 else { return nil }

            let me = ProcessInfo.processInfo.processIdentifier
            let own = content.applications.filter { $0.processID == me }
            let filter = SCContentFilter(display: display, excludingApplications: own, exceptingWindows: [])
            let config = SCStreamConfiguration()
            config.sourceRect = shown.offsetBy(dx: -bounds.minX, dy: -bounds.minY)
            // Full resolution, so small text still reads well.
            let scale = CGFloat(filter.pointPixelScale)
            config.width = max(1, Int((shown.width * scale).rounded()))
            config.height = max(1, Int((shown.height * scale).rounded()))
            config.showsCursor = false
            let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
            return (image, shown)
        } catch {
            return nil
        }
    }

    /// Greyscale copy at the given size in points, one pixel per point.
    /// Drawing smaller averages pixels, so a Retina capture comes out clean.
    static func gray(_ cg: CGImage, width w: Int, height h: Int) -> GrayImage {
        guard w > 0, h > 0 else { return GrayImage(width: 0, height: 0, pixels: []) }
        var pixels = [UInt8](repeating: 0, count: w * h)
        pixels.withUnsafeMutableBytes { buf in
            guard let ctx = CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                                      space: CGColorSpaceCreateDeviceGray(),
                                      bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return }
            ctx.interpolationQuality = .medium
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        }
        return GrayImage(width: w, height: h, pixels: pixels, scale: 1)
    }

    /// Text lines in the image, positioned in points within `pointSize`.
    /// Runs synchronously, so call it off the main thread.
    static func readText(_ cg: CGImage, pointSize: CGSize, fast: Bool) -> [OCRLine] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = fast ? .fast : .accurate
        // UI labels are names and codes, not sentences: don't "correct" them.
        request.usesLanguageCorrection = false
        let handler = VNImageRequestHandler(cgImage: cg, options: [:])
        do { try handler.perform([request]) } catch { return [] }
        let w = pointSize.width, h = pointSize.height
        return (request.results ?? []).compactMap { obs -> OCRLine? in
            guard let best = obs.topCandidates(1).first else { return nil }
            let text = best.string.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            // Vision's boxes are 0...1 with the origin at the bottom left.
            let b = obs.boundingBox
            let frame = CGRect(x: b.minX * w, y: (1 - b.maxY) * h, width: b.width * w, height: b.height * h)
            return OCRLine(text: text, frame: frame, confidence: Double(best.confidence))
        }
    }
}

/// Reads the front window before and after steps, for step checking.
enum ScreenStateReader {
    /// - Parameters:
    ///   - pid: the app to read; the frontmost other app when nil.
    ///   - ocr: also read the text in the pixels, for apps that don't describe themselves.
    ///   - pixels: grab a tiny thumbnail to tell whether anything changed.
    static func read(pid: pid_t?, ocr: Bool, pixels: Bool) async -> ScreenState {
        let me = ProcessInfo.processInfo.processIdentifier
        guard let app = pid.flatMap({ NSRunningApplication(processIdentifier: $0) })
                ?? NSWorkspace.shared.frontmostApplication,
              app.processIdentifier != me else { return ScreenState() }
        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(appElement, 0.5)
        let window = AX.element(appElement, kAXFocusedWindowAttribute)
        let wf = window.flatMap { AX.frame($0) }

        var state = ScreenState(bundleID: app.bundleIdentifier,
                                windowTitle: window.flatMap { AX.string($0, kAXTitleAttribute) },
                                windowSize: wf?.size)
        if let window {
            let found = AX.collect(from: window, origin: wf?.origin, limit: 1200) { AX.matchRoles.contains($0) }
            var seen = Set<String>()
            for f in found {
                guard let label = f.node.label, label.count <= 80 else { continue }
                // Keep repeats: a name showing twice (list and header) is how a step's result shows.
                let key = "\(TextSimilarity.normalize(label))|\(Int(f.snapshot.frame?.midX ?? -1))|\(Int(f.snapshot.frame?.midY ?? -1))"
                guard seen.insert(key).inserted else { continue }
                state.texts.append(SeenText(label, frame: f.snapshot.frame))
            }
        }
        if (ocr || pixels), let wf, let read = await ScreenVision.read(windowFrame: wf, ocr: ocr) {
            if ocr { state.merge(ocr: read.lines) }
            if pixels { state.thumbnail = read.thumbnail }
        }
        return state
    }
}
