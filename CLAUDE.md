# T-Utilities

macOS menu bar app: independent feature modules (local SPM packages `Packages/Mod*`) behind one status item. Swift 6 strict concurrency, SwiftUI + AppKit, XcodeGen (`project.yml`).

## Module rules (mandatory)

Read [Docs/MODULES.md](Docs/MODULES.md) before adding or changing a module. In short: a module depends only on TUCore/TUUI, never knows other modules, acquires resources in `start()` and releases them in `stop()`, stores settings only via `ModuleSettings`, creates event taps only via `SupervisedEventTap`, and has a `ModuleContractTests`. Code shared by two modules goes to TUCore/TUUI, not copied.

`task check` enforces the static rules; `task test` runs it first, then every package's tests; `Scripts/release.sh` refuses to release if either fails. A deliberate exception needs `// module-rules: allow <reason>` and an entry in Docs/MODULES.md §4.

## Commands

- `task build` / `task run` — Debug build (quits the running app first — this also drops the installed app's Awake sleep prevention; ask before running it). Rerun `xcodegen generate` (`task generate`) after adding files or packages.
- `task check` — module rules. `task test` — rules + all package tests (`task test -- ModClipboard` for one).
- `Scripts/release.sh X.Y.Z` — needs `Docs/releases/vX.Y.Z.md` (user-facing notes), a clean tree and a clean `../homebrew-tap` clone.

## Gotchas

- Quit the app (`task quit`) before rebuilding or replacing its bundle, never kill it: an active event tap whose app loses Accessibility stalls system-wide input until the tap supervisor removes it.
- Builds are signed with the self-signed "T-Utilities Dev" certificate (`task cert`) so permissions survive rebuilds.
