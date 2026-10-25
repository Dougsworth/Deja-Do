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

## AI repair

Add an Anthropic API key in Settings (the gear in the sidebar). Only a text list of the window's elements is sent: roles, labels and positions. Never a screenshot and never what you typed. The fixed step is saved, so the next run is fast again.

## Project layout

| Path | What it does |
| --- | --- |
| `Sources/DejaDoCore/MatchEngine.swift` | Scoring, position prediction, anchor consensus, decisions, learning |
| `Sources/DejaDoCore/TextSimilarity.swift` | Fuzzy label matching |
| `Sources/DejaDoCore/Settle.swift` | Knowing when a window has finished changing |
| `Sources/DejaDoCore/Model.swift` | Steps, automations, saving |
| `Sources/DejaDo/AX.swift` | Accessibility: batched attribute reads, tree walks, recording anchors |
| `Sources/DejaDo/Finder.swift` | Gathers what's on screen and asks the engine |
| `Sources/DejaDo/Replayer.swift` | Runs steps, waits for screens to settle, calls the AI and learns |
| `Sources/DejaDo/Recorder.swift` | Event tap for clicks and keys |
| `Sources/DejaDo/AIRepair.swift` | The Claude request |
| `Tests/DejaDoCoreTests` | Engine tests |

Automations are saved as JSON in `~/Library/Application Support/Deja Do/Automations`. Anything recorded while the app was called Once is copied over on first launch.

## Known limits

- Drags, scrolling and hover menus aren't recorded yet
- Some custom drawn apps (games, canvas editors) expose little to Accessibility, so only position and anchor matching works there
- Steps run in order with no loops or variables yet. "Ask each run" on a typing step is the first kind of input
