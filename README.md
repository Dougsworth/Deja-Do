# Deja Do

Do a boring task once. Deja Do does it again, every time after.

Deja Do lives in the menu bar. Press Record, do the task the way you normally would (click, type, switch apps), then Stop. Every action becomes a step you can read and edit. Run it any time and Deja Do does the whole thing again. If a button moved, got renamed or lost its label, Deja Do finds it anyway, and only asks AI when it genuinely isn't sure.

## Build and run

You need Xcode or the Xcode command line tools (`xcode-select --install`).

```bash
./build.sh run     # build "Deja Do.app" and open it
./build.sh test    # run the matching engine's tests
```

Look for the ↻ icon in the menu bar. You can also open `Package.swift` in Xcode to edit and debug.

Every push to `main` builds the app and runs the tests on a Mac in GitHub Actions, and the built app is attached to the run.

## Permissions

The first time, Deja Do asks for two permissions in System Settings › Privacy & Security:

- **Accessibility** to find and press buttons when replaying
- **Input Monitoring** to notice clicks and typing while recording

Switch both on, then quit and reopen Deja Do.

A third one is optional: **Screen Recording** lets Deja Do look at the screen itself, for apps that don't describe their buttons and for checking each step. Turn it on from Settings (the gear in the sidebar).

If you have an Apple Development certificate, `build.sh` signs with it and the permissions stick across rebuilds. Without one it signs ad hoc, and macOS treats every build as a new app, so you have to remove and re-add Deja Do in both lists after rebuilding.

## How it finds things again

Recorded clicks are the hard part. Apps update, windows resize, lists reorder and buttons get renamed. Deja Do treats finding the element as a ranking problem instead of a lookup.

**What it records.** For every click it saves the element's role, title, description, identifier, help text and value, its path through the accessibility tree, its position in the window, the window size, the names of the groups around it ("Toolbar", "Sidebar"), and up to four labelled neighbours with their offsets. Those neighbours are what let it find icon buttons that have no text at all.

**How it scores.** Every element in the window is scored on nine signals, each from 0 to 1:

| Signal | How it's measured |
| --- | --- |
| Role | Exact, or a compatible family (button, pop up and link count as close) |
| Identifier | Exact match, ignoring generated IDs like `_NS:123` or UUIDs that change every launch |
| Text | Fuzzy match that survives changing counters ("Inbox 3" vs "Inbox 12"), punctuation, added words and typo fixes, using edit distance, word overlap and trigram similarity |
| Help, value | Same fuzzy text match |
| Tree path | Edit distance between paths, where a shifted index costs less than a different role |
| Context | Word overlap between the names of surrounding groups |
| Position | Distance from where the element is predicted to be now, not where it was |
| Anchors | How well the element sits where each labelled neighbour says it should |

Position is predicted. The labelled neighbours vote on how far the area around the target moved, and the movement most of them agree on wins, so one neighbour that moved somewhere else can't throw it off. With no neighbours, it tries the ways windows usually reflow on resize (pinned left, right, bottom, or scaled) and keeps the best.

**How it decides.** It acts on its own only when the best match is strong and clearly ahead of the runner up. A label inside its own button isn't counted as a rival. When two candidates are close, it sends the AI the shortlist with its scores. When nothing fits, it sends a wider list.

**How it learns.** Signals are combined with weights kept per app. When the AI picks a different element than the engine would have, the weights shift toward the signals where the right answer won (a pairwise ranking update), so each app needs the AI less over time. Confident matches that drifted a little refresh the saved step so it keeps up with gradual changes.

**Waiting.** Instead of fixed pauses, Deja Do fingerprints the window's accessibility tree and moves on as soon as it stops changing and no spinner is showing.

## When an app doesn't describe its buttons

Canvas apps, games, custom drawn UIs and virtual machine windows tell Accessibility little or nothing. With Screen Recording allowed, every click also keeps a 64 point greyscale picture of the spot and the text around it, read with Apple's Vision framework. On replay, the spot is proposed three ways and every proposal is scored on all the evidence:

| Signal | How it's measured |
| --- | --- |
| Label | The text the click landed on, found again by OCR, with the click kept at the same distance from the label's left edge |
| Nearby text | Lines of text around the click vote on how far things moved, like the anchors above |
| Picture | Normalised cross correlation of the recorded picture, coarse to fine, at three sizes. A detail only score keeps lookalike icons apart, and it ignores tints and dark mode |
| Position | Distance from where the spot should be after the window moved or resized |

The decision works like the accessibility engine: it clicks only when the best spot is strong and clearly ahead of the next distinct one, so two identical "Reply" buttons are never guessed between. The screen is used first for clicks recorded only by position and for clicks on one huge unlabelled element (a VM's guest screen). For everything else it is a fallback tried before asking the AI.

## Checking each step

Recording notes how the screen changed after every click and key press: text that appeared (a chat's header now showing the person you clicked), text that went away (a closed dialog), a new window title or app, or just that the pixels changed. Clocks, "2 min ago", "typing…" and counters are ignored. Each step shows what it expects in the step list.

On a run, the screen is read before and after each of those steps and compared. If it doesn't match, Deja Do waits a little in case the app is slow. If nothing changed at all, it tries the step once more. If the screen changed in some other way it never repeats the step, because a second click could undo a toggle or send something twice, and stops instead with what it expected to see. Each step can be set to try again then stop (the default), stop right away, or keep going.

Only a few short labels are kept for this, never a copy of the screen. When a task types from {{variables}} or asks each run, text that came from typing isn't expected to show up again.

## AI repair

Add an Anthropic API key in Settings (the gear in the sidebar). Only a text list of the window's elements is sent: roles, labels and positions. Never a screenshot or the recorded pictures, and never what you typed. The fixed step is saved, so the next run is fast again.

## Project layout

| Path | What it does |
| --- | --- |
| `Sources/DejaDoCore/MatchEngine.swift` | Scoring, position prediction, anchor consensus, decisions, learning |
| `Sources/DejaDoCore/TextSimilarity.swift` | Fuzzy label matching |
| `Sources/DejaDoCore/VisualMatch.swift` | Finding a spot again by its label, nearby text and picture |
| `Sources/DejaDoCore/TemplateSearch.swift` | Coarse to fine picture matching |
| `Sources/DejaDoCore/GrayImage.swift` | Small greyscale pictures, resizing and filters |
| `Sources/DejaDoCore/StepCheck.swift` | What a step changed, checking it on a run, retry decisions |
| `Sources/DejaDoCore/Settle.swift` | Knowing when a window has finished changing |
| `Sources/DejaDoCore/Model.swift` | Steps, automations, saving |
| `Sources/DejaDo/AX.swift` | Accessibility: batched attribute reads, tree walks, recording anchors |
| `Sources/DejaDo/Finder.swift` | Gathers what's on screen and asks the engine |
| `Sources/DejaDo/Replayer.swift` | Runs steps, waits for screens to settle, calls the AI and learns |
| `Sources/DejaDo/Recorder.swift` | Event tap for clicks and keys |
| `Sources/DejaDo/AIRepair.swift` | The Claude request |
| `Sources/DejaDo/ScreenVision.swift` | ScreenCaptureKit capture, Vision text reading, before and after reads |
| `Tests/DejaDoCoreTests` | Engine, vision and step checking tests. They also run on Linux |

Automations are saved as JSON in `~/Library/Application Support/Deja Do/Automations`. Anything recorded while the app was called Once is copied over on first launch.

## Known limits

- Drags, scrolling and hover menus aren't recorded yet
- Without Screen Recording, custom drawn apps (games, canvas editors, VMs) fall back to clicking the recorded position
- The picture for a click is taken just after the mouse goes down, so a button that changes colour the instant it's pressed is matched mostly on its shape and surroundings
- Recorded pictures are saved inside the task and travel with exported .dejado files
- Steps run in order with no loops or variables yet. "Ask each run" on a typing step is the first kind of input
