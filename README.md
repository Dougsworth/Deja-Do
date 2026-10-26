# Deja Do

Do a boring task once. Deja Do does it again, every time after.

Deja Do lives in the menu bar. Press Record, do the task the way you normally would (click, type, switch apps), then Stop. Every action becomes a step you can read and edit. Run it any time and Deja Do does the whole thing again. If a button moved, got renamed or lost its label, Deja Do finds it anyway, and only asks AI when it genuinely isn't sure.

## Build and run

You need Xcode or the Xcode command line tools (`xcode-select --install`).

```bash
./build.sh run     # build "Deja Do.app" and open it
./build.sh test    # run the matching engine's tests
./build.sh selftest   # drive Calculator, a web form in Safari and TextEdit with real clicks (results in self-test.txt)
./build.sh release    # sign with Developer ID, notarize, and zip it to send to people
```

The self test drives real apps with real mouse and keyboard events. Keep hands off for about seven minutes. `SUITE=calculator`, `SUITE=web` or `SUITE=apps` runs one part.

- **Calculator.** Records 7 + 8 =, replays it as recorded, in the Scientific layout, after the window moves, and from the screen alone. Checks that a step whose screen doesn't match stops without repeating, that another app jumping in front is handled, that Esc stops a long wait at once, and that the task can be started over the local web address (no token refused, a run waited on, a second request told it's busy).
- **Web form.** Deja Do serves itself a small form and opens it in Safari. The page can break itself the ways real sites do, and it counts every real submission, so "sent exactly once" is proven rather than assumed. One recording is replayed against fourteen versions: unchanged, button renamed, button relabelled to a different word, fields reordered and button moved, form loading late, result showing slowly, form below the fold, DOM ids random on each load, a lookalike button beside the real one, a cookie banner over the form (before and after Deja Do is shown how to close it), a new confirm dialog, all of the above at once, and the same form on a different website. Each must submit exactly once with the right values or stop with nothing sent. Submitting twice fails the whole run.
- **Desktop apps.** Records typing and ⌘S in TextEdit, replays it into a new document (the text must land once), and checks a ⌘S whose result doesn't match stops without being pressed again. Also checks that a running Electron app describes its buttons once asked.

`./build.sh watch` waits for a `.selftest-request` file in the folder (its contents can name a suite) and runs the self test each time one appears, so changes can be tested without anyone at the keyboard.

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

## Safety

Deja Do assumes a run can go wrong and is built to stop cleanly rather than guess.

- **Risky steps.** Clicks on Send, Save, Submit, Delete, Pay and the like, Return after typing, ⌘S and ⌘⌫ are marked as risky (you can change it per step). A risky step is never repeated, never clicked by its old position, never clicked from a picture match alone, and an AI pick for one is confirmed with you first. Settings can also ask before every risky step.
- **The right app, every time.** Before each click and key press, the app the step belongs to must be in front. If something else jumped in, it's brought back once; if that fails, the run stops before sending anything. Typing stops mid word if focus is lost.
- **Nothing in the way.** Right before a click, Deja Do checks what's under the pointer. If a banner, popover or sheet covers the target, it waits, looks again once, then stops.
- **Typing that landed.** After typing, the field is read back. Nothing arrived: typed once more. Part arrived: stop, so it isn't typed twice.
- **Repairs can't drift.** Self healing and AI fixes are held to what the step was first recorded as, so many small repairs can't walk a step onto a different button. AI fixes can be undone from the step's menu.
- **Clear endings.** Each run ends saying whether anything was sent or saved before it stopped. Spreadsheet runs offer to continue from the right row, skipping a row that may already have gone through.
- **Partial scans aren't trusted.** Reading a window has a time limit and a node limit; a match from a scan that was cut short isn't treated as certain.
- **Same website only.** A step recorded on a web page remembers the site. If the browser is on a different site, the run stops rather than click a page that only looks the same.
- **Saved tasks never vanish quietly.** Damaged or newer-format task files are reported and left untouched, imported files are checked first, and deleting moves a task to the Trash.

## Web pages

Safari, Chrome, Edge, Brave, Arc and Electron apps are read through the same Accessibility interface as native apps, once Deja Do asks them to switch it on. Each control's DOM id is used like an app's own identifier, so a button that is renamed or relabelled is still found. Ids that web frameworks make up at load time (`mui-12`, `:r3:`, `field-482`) are recognised and ignored. Popups that come and go on their own, like a browser's autofill list, are never taken as a step's result.

## Starting tasks from other tools

Turn on **Let tools on this Mac start tasks** in Settings and Deja Do listens at `http://127.0.0.1:7357`, on this Mac only. Every call except `/health` needs the token shown there (**Copy example request** copies a ready-made `curl` with it).

```bash
# What can be run, and the {{variables}} each task needs
curl -H "Authorization: Bearer $TOKEN" http://127.0.0.1:7357/tasks

# Run a task and wait for the result
curl -X POST http://127.0.0.1:7357/run \
  -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
  -d '{"task": "Send invoice", "values": {"client": "Ana", "amount": "120"}, "wait": true}'

# Or start it, get a run id straight away, and be called back when it ends
  -d '{"task": "Send invoice", "values": {...}, "callback": "http://localhost:5678/webhook/dejado-done"}'
curl -H "Authorization: Bearer $TOKEN" http://127.0.0.1:7357/runs/<runId>
```

The result says `succeeded`, `failed` or `cancelled`, what each step did, and `mayHaveChangedThings`, which is true when a step that sends, saves or deletes may have run before a stop, so the caller knows not to simply retry. Typed values are never sent back. Callbacks carry `X-DejaDo-Signature: sha256=…`, an HMAC of the body keyed by the token, so the receiver can check they came from this Mac. While Deja Do is running or recording, a new request gets `409` with `retryAfter`.

**n8n on the same Mac:** an HTTP Request node, method POST, URL `http://127.0.0.1:7357/run`, header `Authorization: Bearer <token>`, JSON body as above with `"wait": true`. The node's output is the run result.

The address only answers on this Mac, refuses requests that come from a web page or through a rebound domain name, and is off until turned on. Cloud services such as Zapier and Make can't reach it directly; they need a relay, which is planned for the Deja Do server.

## Repair records

Every time finding a step wasn't straightforward (a control was healed, AI picked one, it was found from the screen, it was clicked by position, or it wasn't found), Deja Do notes how the control was described then and now, and how each matching signal scored. Never typed text or field contents. The file stays on the Mac at `~/Library/Application Support/Deja Do/repairs.jsonl`, keeps the newest 5,000, and can be saved from Settings. It is the data the matcher's thresholds and weights get tuned from.

## Help while editing

- **Check** looks for every button on screen without clicking or typing anything.
- **Variables** are suggested from the name of the field you typed into, or from what the value looks like (email, date, amount, phone).
- **Tidying**: clicks that changed nothing and stray ⌘Tab at the end are pointed out, never removed on their own.
- **Popups**: when something like "What's New" blocks a run, click "Something in the way?" and close it once; Deja Do closes it whenever it shows up after that.
- **Scrolling**: when a button isn't visible, the list it was recorded in is scrolled until it shows up.
- **Run history** keeps the last 30 runs of each task: what each step did, never what was typed.
- **Agent skills**: add a task as a skill for Claude Code and Codex. Agents run it through a `dejado://run?task=…` link, which asks you first unless you allow other apps in Settings.

Ideas and some rules here come from [OpenAdapt](https://github.com/OpenAdaptAI/OpenAdapt) and [MacTape](https://github.com/jovial-liu/MacTape) (both MIT, credited in the code) and [open-record-replay](https://github.com/video-db/open-record-replay) (ideas only).

## AI repair

Pick the AI service in Settings:

| Service | What it needs |
| --- | --- |
| Deja Do | An access code. Requests go through your own server, which holds the keys (see `server/README.md`) |
| Anthropic | Your Anthropic key: Claude Haiku, Sonnet or Opus 5.5 |
| OpenAI | Your OpenAI key: GPT-6 Luna or GPT-6.1 Sol |
| Google Gemini | Your Gemini key: Gemini 3.5 Flash Lite, 3.8 Flash or 4 Argon |
| Ollama | Nothing. Runs a model on the Mac, free and private. Install Ollama and pull a model |

Keys are kept in the keychain. Only a text list of the window's elements is sent: roles, labels and positions. Never a screenshot or the recorded pictures, and never what you typed. The fixed step is saved, so the next run is fast again.

## Project layout

| Path | What it does |
| --- | --- |
| `Sources/DejaDoCore/MatchEngine.swift` | Scoring, position prediction, anchor consensus, decisions, learning |
| `Sources/DejaDoCore/TextSimilarity.swift` | Fuzzy label matching |
| `Sources/DejaDoCore/VisualMatch.swift` | Finding a spot again by its label, nearby text and picture |
| `Sources/DejaDoCore/TemplateSearch.swift` | Coarse to fine picture matching |
| `Sources/DejaDoCore/GrayImage.swift` | Small greyscale pictures, resizing and filters |
| `Sources/DejaDoCore/StepCheck.swift` | What a step changed, checking it on a run, retry decisions |
| `Sources/DejaDoCore/Risk.swift`, `Safety.swift` | Risky steps, typing checks, repair guard, how a run ended |
| `Sources/DejaDoCore/Corpus.swift` | Repair records |
| `Sources/DejaDoCore/Webhooks.swift`, `Sources/DejaDo/WebhookServer.swift` | The local web address other tools start tasks through |
| `Sources/DejaDo/SelfTest.swift`, `WebSelfTest.swift`, `AppsSelfTest.swift` | End to end tests on Calculator, Safari and TextEdit |
| `Sources/DejaDo/TestServer.swift` | The breakable web form the web test uses |
| `Sources/DejaDoCore/Settle.swift` | Knowing when a window has finished changing |
| `Sources/DejaDoCore/Model.swift` | Steps, automations, saving |
| `Sources/DejaDo/AX.swift` | Accessibility: batched attribute reads, tree walks, recording anchors |
| `Sources/DejaDo/Finder.swift` | Gathers what's on screen and asks the engine |
| `Sources/DejaDo/Replayer.swift` | Runs steps, waits for screens to settle, calls the AI and learns |
| `Sources/DejaDo/Recorder.swift` | Event tap for clicks and keys |
| `Sources/DejaDoCore/AIProviders.swift` | Requests and replies for each AI service |
| `Sources/DejaDo/AIRepair.swift` | The question sent to the AI |
| `server/` | The Deja Do AI server for Dokploy |
| `Sources/DejaDo/ScreenVision.swift` | ScreenCaptureKit capture, Vision text reading, before and after reads |
| `Tests/DejaDoCoreTests` | 161 engine, vision, step checking and safety tests. They also run on Linux |

Automations are saved as JSON in `~/Library/Application Support/Deja Do/Automations`. Anything recorded while the app was called Once is copied over on first launch.

## Known limits

- Drags, scrolling and hover menus aren't recorded yet
- Without Screen Recording, custom drawn apps (games, canvas editors, VMs) fall back to clicking the recorded position
- The picture for a click is taken just after the mouse goes down, so a button that changes colour the instant it's pressed is matched mostly on its shape and surroundings
- Recorded pictures are saved inside the task and travel with exported .dejado files
- Steps run in order with no loops or variables yet. "Ask each run" on a typing step is the first kind of input
