# Projects: design & requirements

Status: v4. Spikes S1–S5 done. M1 (core), M2 (lifecycle) and per-window ownership (§4a) implemented,
M3 (router) pending.

## 1. Problem

The user works on several projects in parallel. Each project uses its own **dedicated app instances**
(a separate Chrome, a separate kitty+Herdr, ...). Switching to a project must:

- hide all windows that belong to **other** projects,
- show the windows of the **target** project,
- leave windows that belong to **no** project untouched.

The existing AeroSpace workflow on 2 monitors must keep working unchanged: switching workspaces/monitors,
moving workspaces between monitors, moving windows between workspaces.

### Non-goals (this stage)

- Per-project Slack/Teams/Outlook instances (Slack profiles are explicitly out of scope for now).
- Per-monitor active project.

Splitting the windows of a **single** process between projects (one personal Chrome shared by all projects) was a
non-goal of M1/M2. It's implemented now, see [§4a Per-window ownership](#4a-per-window-ownership).

## 2. Target setup

|                       | `anna`                                         | `bob`                                        | `company`                                          | Global (never touched)                        |
|-----------------------|------------------------------------------------|----------------------------------------------|----------------------------------------------------|-----------------------------------------------|
| Chrome                | own instance, `--user-data-dir=…/chrome/anna`  | own instance, `--user-data-dir=…/chrome/bob` | own instance, `--user-data-dir=…/chrome/company`   | "personal" Chrome (default data dir), on demand |
| kitty + Herdr         | `--instance-group anna`, Herdr session `anna`  | `--instance-group bob`, Herdr session `bob`  | `--instance-group company`, session `company`, **on demand** | plain kitty (no instance group), on demand    |
| Cursor                | own instance, `--user-data-dir ~/.cursor-projects/anna`, 1+ repo windows | own instance, `…/bob`, 1+ repo windows | own instance, `…/company`, 1+ repo windows | personal Cursor (default data dir), on demand |
| Firefox               | –                                              | –                                            | **whole app**                                      | –                                             |
| Slack, Teams, Outlook | –                                              | –                                            | –                                                  | ✔                                             |

## 3. Key design decisions

### D-1. A project owns app **processes**, not windows

Ownership is decided per process (PID). Every window of a process inherits the process's project:
new windows, dialogs, torn-off tabs are attributed automatically with no per-window rules.
A process that matches no project is **global**.

Rationale: all target apps support a dedicated instance per project, and process-level ownership is
robust (no title heuristics) and survives restarts (matching uses launch arguments, not PIDs).

Exception: per-window apps (`window-if`), where one process is shared by all projects. See §4a.

### D-2. Switching uses macOS native app hiding

`project <name>` calls `NSRunningApplication.unhide()` on the target project's processes and `hide()` on
the processes of all other projects.

AeroSpace already handles hidden apps: `_normalizeLayoutReason` (`Sources/AppBundle/normalizeLayoutReason.swift`)
moves windows of hidden apps into the per-workspace `MacosHiddenAppsWindowsContainer` and
`exitMacOsNativeUnconventionalState` brings them back on unhide. So the tree, layout and all commands
already ignore hidden windows. Benefits over corner-hiding individual windows:

- far less new code, smaller diff against upstream;
- Mission Control and the corners stay clean;
- Cmd-Tab / Dock / notification clicks unhide natively, and AeroSpace only needs to react (R4).

Known gap: today an unhidden tiling window is re-inserted next to the MRU window (`relayoutWindow(forceTile: true)`),
not into its previous position. Must be fixed (R3.3).

### D-3. Workspaces are roles; projects choose their content

Anna's, Bob's and Company's Chrome all live on the same workspace (e.g. `B`); only one is visible at a time.
Workspace names keep stable meaning (`T` terminal, `B` browser, `C` comms) regardless of the active
project, so keybindings and the monitor setup stay unchanged. The project does not own workspaces.

### D-4. One active project, global for all monitors

There is exactly one active project, or none. With none, only global apps are visible.

### D-5. Links are routed by the opener's project

Clicking a link in Anna's kitty opens Anna's Chrome. Links from global apps (Slack, Teams, Outlook)
open in the global personal Chrome. Implemented by a small external URL router + an AeroSpace query (R6).

## 4. Requirements

MUST unless marked SHOULD/MAY.

### R1. Model & config

- **R1.1** App definitions (`[project-apps.<id>]`) are declared once and referenced by projects.
  Each has a matcher (`if`, same syntax as `on-window-detected`) and an optional `launch` shell command.
  Optional `bundle-id` and `global-launch` serve R5.1b (`global-launch` requires `bundle-id` and must not contain
  `{project}`).
- **R1.2** Two kinds of app definitions:
  - **Shared**: matcher/launch contain the `{project}` placeholder. Each project referencing it gets its own instance.
  - **Whole-app**: no placeholder. All processes of the app belong to the single project that references it.
    Referencing a whole-app definition from 2+ projects is a config error.
- **R1.3** Projects are an ordered array (`[[projects]]`), which defines `project next|prev` order.
- **R1.4** Project names match `[a-z0-9_-]+` so that `{project}` substitution is regex- and shell-safe.
- **R1.5** Each project entry may override per-app options, at least `autostart` (R5.2) and `open`:
  a list of items (e.g. repo folders) substituted into the launch command as `{open}`
  (shell-quoted, space-separated, leading `~` expanded to `$HOME`). `open` without `{open}` in `launch` is a config error.
  Example: Anna's Cursor opens `~/src/anna-api` and `~/src/anna-web`, one window per folder, all owned by `anna`.
- **R1.6** Each project declares a `link-browser` (app id) used by the router (R6). Defaults to `chrome` if referenced.
- **R1.7** Match conflict resolution: a shared (argument-specific) match beats a whole-app match;
  a remaining tie is reported as a config error on load (`reload-config` shows it).
- **R1.8** Everything that matches no project is global. No configuration needed for Slack/Teams/Outlook/personal Chrome.

### R2. Process identification

- **R2.1** New interpolation variable `%{app-args}`: the process command line (via `sysctl(KERN_PROCARGS2)`),
  available in `test`, `list-apps`, `list-windows` and matchers.
- **R2.2** New interpolation variables `%{app-project}` and `%{window-project}` (empty for global).
- **R2.3** A process is matched once on app registration (launch or AeroSpace startup); the result is cached per PID
  and recomputed on `reload-config`.
- **R2.4** SHOULD: `move-app-to-project <project|--none> [--pid <pid>]` manual override for processes no rule matches.
  Lives until the process exits. ✅ M2: the override beats config rules (also for matched processes), survives
  `reload-config` and AeroSpace restarts (state file, validated by pid + argv), is dropped when its project is removed
  from the config, and re-applies visibility immediately.

### R3. Switching

- **R3.1** `project <name>`: unhide the target's processes **first**, then hide other projects' processes
  (minimizes flicker, mirrors `layoutWorkspaces` ordering). Global apps are not touched.
- **R3.2** Focus after switch: the target project's MRU window; if none (or it is gone) the top window of the focused
  workspace; otherwise the empty focused workspace.
- **R3.3** An unhidden window returns to its **exact** previous place: workspace, parent container, index, weight.
  Fallback to the current behavior if the parent container no longer exists.
- **R3.4** `project --none`, `project-back-and-forth`, `project next|prev [--wrap-around]`.
- **R3.5** AeroSpace tracks which PIDs **it** hid. User's own Cmd-H / Cmd-Alt-H stay user-owned and are not undone by
  project switching.
- **R3.6** `automatically-unhide-macos-hidden-apps = true` must not unhide project-hidden apps
  (`GlobalObserver.onHideApp` currently unhides **all** apps).
- **R3.7** The active project is persisted (state file) and restored on AeroSpace start; on start all inactive projects'
  processes are hidden.
- **R3.8** `enable off` and AeroSpace quit unhide all project-hidden apps.
- **R3.9** Hidden windows keep their workspace. Since `MacosHiddenAppsWindowsContainer` is a workspace child,
  `move-workspace-to-monitor` carries them along, and the workspace is not garbage-collected
  (`isEffectivelyEmpty` is false).
- **R3.10** SHOULD: `workspace next|prev` option to skip workspaces whose only windows are hidden
  (e.g. `T` while `company` has no running kitty).
- **R3.11** SHOULD: switch latency < 150 ms perceived for ~3 apps × ~10 windows (validated in spike S2).

### R4. Activation from outside

When a process of an inactive project gets unhidden/activated externally (Cmd-Tab, Dock click, notification click),
apply `on-inactive-project-activation`:

- `switch` (default): switch to that project.
- `rehide`: hide it again, keep the current project.
- MAY (later): `peek`: show just that app over the current project.

### R5. Lifecycle

- **R5.1** `project-launch [--project <name>] [--app <id>...]`: start missing instances of a project
  (default: active project). With `--app` and the instance already running: focus its MRU window
  ("launch or focus"). Exit code 1 if the project has no such app, so bindings can fall back to global:
  `alt-enter = 'project-launch --app kitty || exec-and-forget open -na kitty'`.
  Note (M2): that binding doesn't parse: `exec-and-forget` is only recognized as the first command of a binding
  ("Unrecognized subcommand 'exec-and-forget'"). Working form: `'exec-and-forget aerospace project-launch --app kitty || open -na kitty'`.
  ✅ M2, with these decisions:
  - Syntax is `--app <id>...` / `--open <item>...` (space-separated values after one flag, like
    `list-windows --workspace <ws>...`): the CLI parser rejects repeated flags.
  - Failure exit code is 2 (`BinaryExitCode.fail`, used by every AeroSpace command, incl. M1 `project`). `||` works the same.
  - Without `--app`: apps without `launch` are skipped. With `--app`: an app without `launch` is an error.
  - "Instance" = processes owned by the project that match the app's matcher.
  - Running instance of an **inactive** project (`--project`): switch to the project, focusing that app (like R4 `switch`).
  - Running instance without a focusable window (e.g. all windows closed or minimized): run `launch`.
  - MRU per instance: a global MRU list of window ids (last 100) maintained next to the per-project MRU.
  - All checks run before any side effect (one unknown `--app` launches nothing).
- **R5.1a** ✅ `project-launch --app <id> --open <item>...` (exactly one `--app`) opens extra items in the project's instance
  (e.g. a third repo in Anna's Cursor: `cursor --user-data-dir ~/.cursor-projects/anna <folder>` reuses the running instance).
  Cursor restores its previous windows on restart, so `open` mainly matters for the first start.
- **R5.1b** ✅ With no active project, `project-launch --app <id>` targets the **global** instance of that app: the process
  with the app's bundle ID (explicit `bundle-id` key, not derived from the matcher) that matches no project. Focus its MRU window if running, otherwise run the app definition's
  `global-launch` command (e.g. `open -na "Google Chrome"`). Never activate by bundle ID (`osascript … activate`,
  `open -a`): with several instances running it picks an arbitrary one.
- **R5.2** ✅ Per-app `autostart` (default `true`). `project <name> --launch-missing` starts only `autostart` apps.
  `company.kitty` is `autostart = false` (on demand).
- **R5.3** ✅ SHOULD: `project-quit [<name>]` gracefully quits all instances of a project (Herdr sessions survive).
  `NSRunningApplication.terminate()` for every process owned by the project (default: active). No force-kill.
  The active project stays active. Processes of an inactive project are not unhidden first, so quit confirmations
  (e.g. Chrome "close N tabs?") stay invisible until the project is activated.
- **R5.4** ✅ `launch` commands get `AEROSPACE_PROJECT=<name>` in the environment (empty for `global-launch`).
  They don't get `AEROSPACE_WINDOW_ID`/`AEROSPACE_WORKSPACE`: the launched app would inherit them.

### R6. Link routing

- **R6.1** AeroSpace query: `aerospace list-apps --pid <pid> --format '%{app-project}'`. Must be fast (< 20 ms).
- **R6.2** A small external URL router registered as the default browser (separate tool, not part of AeroSpace.app):
  1. Resolve the opener PID from the Apple Event sender (`keySenderPIDAttr`).
  2. Walk up the parent chain. For each process: if it is a GUI app owned by project P → P. If its env has
     `HERDR_SOCKET_PATH` of a session mapped to project P → P (Herdr panes are re-parented to launchd, see S3).
  3. Sender already exited (race, see S3) → project of AeroSpace's focused window.
  4. Project P found → run P's `link-browser` launch command with the URL. Chrome forwards it to the
     running instance with the same `--user-data-dir`.
  5. Opener is global or unknown → personal (global) Chrome.
- **R6.4** Each project maps to a Herdr session (default: session name = project name) so the router and
  `kitty` launch command agree.
- **R6.3** Router never starts a second instance of an already running Chrome profile.

### R7. Introspection & integration

- **R7.1** `list-projects [--active] [--format ...] [--json]`: `%{project-name}`, `%{project-is-active}`,
  per-app running state.
- **R7.2** `list-windows --project <name|--none|--active>`, `list-apps --project ...`.
  `list-windows --project` alone implies `--monitor all` (M2).
- **R7.3** `subscribe` event `project-changed` and config callback `on-project-changed` (sketchybar etc.).
  `on-project-changed` commands get `AEROSPACE_PROJECT` and `AEROSPACE_PREV_PROJECT` env variables (empty for none) (M2).
  `subscribe` streams JSON events and runs no commands, so it needs no env variables.

### R8. Non-functional

- **R8.1** Existing commands keep their semantics. With no `[[projects]]` in config, behavior is identical to upstream.
- **R8.2** Keep the diff self-contained (new files where possible) so the fork rebases on upstream cleanly.
- **R8.3** Unit tests for ownership matching, conflict resolution, switch/focus logic, exact restore (R3.3).
- **R8.4** Docs: `docs/aerospace-project*.adoc`, `docs/commands.adoc`, `docs/guide.adoc` section, shell completion
  grammar (see command checklist in `architecture.md`).

## 4a. Per-window ownership

✅ Implemented (`Sources/AppBundle/project/projectWindows.swift`).

Use case: ONE personal Chrome (logins kept) shared by all projects, each Chrome window belongs to a project.
Native app hiding (D-2) can't be used: it hides all windows of the process. Windows are hidden one by one.

Verified facts (macOS 27, Chrome 155): Chrome's "Name window…" (AppleScript `given name` of a window) changes the AX
title to `<name> - Google Chrome`. `tell application id "com.google.Chrome" to set given name of window 1 to "anna"`
names the frontmost Chrome window (`window 1` = most recently active). Whether Chrome restores window names after a
restart is **unverified**, the design doesn't depend on it.

- **W1. Config.** `[project-apps.<id>]` with `window-if` is a *per-window* definition: `if` selects the process(es),
  `window-if` (same restricted matcher syntax, `%{window-*}` allowed except `%{window-project}`, `{project}` substituted)
  decides the project of each window. A per-window definition may be referenced by many projects (the whole-app
  restriction of R1.2 doesn't apply). Per-window definitions don't take part in process ownership (R1.7).
  `new-windows = 'active-project' | 'global'` (default `global`) and `on-window-assigned = '<commands>'` require `window-if`.
- **W2. Precedence** for a window: `move-window-to-project` override (by window id) > `window-if` match > ownership of
  the process (normally global for per-window processes; `move-app-to-project` can change it). A `window-if` tie
  (2+ projects) is treated as global. `%{window-project}`, `list-windows --project`, per-project MRU, focus after switch,
  `list-projects` running state use the window's project. `%{app-project}` / `list-apps --project` stay per process.
- **W3. Title cache.** `window-if` results are cached per window id and recomputed at the beginning of every
  `normalizeLayoutReason` (titles change; an AX title read per window of per-window processes only).
  Renaming a Chrome window via Chrome UI therefore moves it between projects at the next refresh.
- **W4. Hiding.** A per-window process is never hidden as a whole (excluded from the R3.1 visibility plan; if AeroSpace
  hid it earlier, it's unhidden). A window of such a process that belongs to an inactive project is *project-hidden*.
  `normalizeLayoutReason` moves project-hidden windows into the per-workspace `MacosHiddenAppsWindowsContainer` exactly
  like windows of hidden apps (same `layoutReason = .macos(prevParentKind:)` + `prevTilingBinding`), and brings them back
  with the same exact-restore path (R3.3). `layoutWorkspaces` parks them in the monitor corner (`hideInCorner`) also on
  visible workspaces, and skips `unhideFromCorner` for them; floating windows restore their position via the usual
  `unhideFromCorner` after they're back in the floating container. Reusing the container (instead of a new tree node
  kind) means every command, mouse handler, focus logic, workspace GC (R3.9) and `move-workspace-to-monitor` already
  ignore/carry these windows, with no changes to the ~15 `switch` statements over container kinds.
  A window that gets unminimized/leaves fullscreen while project-hidden is moved to the hidden container right away.
  `enable off` → `isWindowHiddenByProject` is false for a disabled AeroSpace → windows come back. Quit → the
  termination handler puts all windows on screen.
- **W5. Exact order.** Remembered indices alone break when windows come back in a different order than they left
  (e.g. A hidden, B hidden, `project --none` hides C, back to A's project: A and B return while C stays hidden).
  All windows that left the same tiling container now share a `TilingChildrenOrder` (weak list of the siblings incl.
  left windows); a returning window is inserted right after its nearest remembered predecessor that is present.
  The index stays as a fallback. This also fixes the same issue for macOS hidden/minimized windows.
- **W6. New windows.** For every newly detected window (not at startup, not restored from the closed-windows cache,
  not a popup) of a per-window process without an override whose `window-if` matches nothing: assign it to the project
  of a pending `project-launch` (W9), else to the active project if it references a per-window app with
  `new-windows = 'active-project'` matching the process. The assignment is stored as an override (so it doesn't depend
  on Chrome naming the window).
- **W7. `on-window-assigned`.** Runs after an assignment (W6 or `move-window-to-project`) with `AEROSPACE_PROJECT`
  (empty for global) and `AEROSPACE_WINDOW_ID`. Before running, the window is natively focused so that Chrome's
  `window 1` is that window. Race: when the window goes to an inactive project, hiding it and re-focusing another
  (possibly Chrome) window would change `window 1` before the asynchronous `osascript` runs. So AeroSpace waits for the
  processes spawned by `exec-and-forget` in the callback (up to 3 s) before re-applying visibility and focus.
- **W8. R4 per window.** In both refresh sessions, before `updateFocusCache`: if the native focus *changed* to a
  project-hidden window (cmd-tab brings Chrome's last active window, Dock click, notification), apply
  `on-inactive-project-activation`: `switch` → switch to the window's project focusing that window; `rehide` → give the
  native focus back to AeroSpace's focused window. Guards against our own focus changes: ignored while a switch/assignment
  is in progress and for 1 s after AeroSpace hid the window; the native focus is then marked as seen, so a native focus
  that stays on a parked window (e.g. switch to a project with no windows) doesn't trigger R4 later.
  The process-level R4 (`handleInactiveProjectActivation`) skips per-window processes.
- **W9. `project-launch`.** Per-window app is "running" for a project if the project owns at least one of its windows.
  `--app`: focus the project's MRU window of the app (switch to the project if inactive, focusing that window);
  no windows → run `launch` (e.g. `open -na "Google Chrome" --args --new-window`) and register a pending assignment
  (project, app id, 10 s): the next new window of the app goes to that project even if `new-windows = 'global'` or the
  project is inactive. `project --launch-missing` treats per-window apps the same way. `project-quit` doesn't quit
  per-window processes (they're shared).
- **W10. `move-window-to-project <name|--none> [--window-id <id>]`.** Override for one window (default: focused) of a
  per-window process (error otherwise), runs `on-window-assigned`, re-applies visibility, re-focuses if the focused window
  got hidden, gives the native focus back.
- **W11. State.** Window overrides are persisted in the state file as `windowOwnershipOverrides`
  (`windowId`, `pid`, `project`, `args`), restored only if the window still exists in the same process (pid + argv), and
  dropped when the process or the window is gone, or when the project is removed from the config.

Open points:
- Not verified live (unit tests only): parking/unparking frames, Chrome window naming via `on-window-assigned`,
  R4 timing (1 s grace), cmd-tab/Dock behaviour of Chrome with parked windows.
- A popup that later turns into a regular window (validateStillPopups) doesn't get a W6 assignment.
- Parked windows of a visible workspace still appear in Mission Control / App Exposé (corner-parked, like windows of
  invisible workspaces).

## 5. Config sketch (syntax not final)

```toml
on-inactive-project-activation = 'switch' # top-level keys before any [table]

# `--` lets the rhs of `test` start with a dash
[project-apps.chrome]  # shared
if = 'test %{app-bundle-id} = com.google.Chrome && test %{app-args} ~= -- "--user-data-dir=.*/\.chrome/{project}( |$)"'
launch = 'open -na "Google Chrome" --args --user-data-dir="$HOME/.chrome/{project}"'
bundle-id = 'com.google.Chrome'             # R5.1b: finds the global (personal) Chrome
global-launch = 'open -na "Google Chrome"'  # R5.1b: no active project and no global Chrome running

[project-apps.kitty]   # shared
if = 'test %{app-bundle-id} = net.kovidgoyal.kitty && test %{app-args} ~= -- "--instance-group[= ]{project}( |$)"'
launch = 'kitty --single-instance --instance-group {project} herdr --session {project}'

[project-apps.cursor]  # shared; several windows (repos) per instance
if = 'test %{app-bundle-id} = com.todesktop.230313mzl4w4u92 && test %{app-args} ~= -- "--user-data-dir[= ].*/\.cursor-projects/{project}( |$)"'
launch = 'cursor --user-data-dir ~/.cursor-projects/{project} {open}'  # not `open -na`, see S5

[project-apps.firefox] # whole app
if = 'test %{app-bundle-id} = org.mozilla.firefox'
launch = 'open -a Firefox'

[[projects]]
name = 'anna'
apps = ['chrome', 'kitty', { app = 'cursor', open = ['~/src/anna-api', '~/src/anna-web'] }]

[[projects]]
name = 'bob'
apps = ['chrome', 'kitty', { app = 'cursor', open = ['~/src/bob-app'] }]

[[projects]]
name = 'company'
apps = ['chrome', 'firefox', { app = 'kitty', autostart = false }, { app = 'cursor', open = ['~/src/company-infra'] }]
link-browser = 'chrome'

[mode.main.binding]
alt-p = 'project next --wrap-around'
alt-shift-p = 'project-back-and-forth'
alt-enter = 'exec-and-forget aerospace project-launch --app kitty || open -na kitty'  # see R5.1 note
alt-b = 'project-launch --app chrome'  # no active project -> the global Chrome (R5.1b)
```

## 6. Implementation notes

| Area | Where | Change |
|---|---|---|
| Config | `Sources/AppBundle/config/` | parse `[project-apps.*]`, `[[projects]]`, `on-inactive-project-activation`; validate R1.2/R1.4/R1.7 |
| `%{app-args}` | `MacApp` + interpolation vars | lazily read & cache `KERN_PROCARGS2` per PID |
| Ownership | new `ProjectRegistry` (MainActor) | PID → project cache, active project, AeroSpace-hidden PID set, per-project MRU window |
| Switching | new `ProjectCommand` | unhide target → hide others → refresh session → focus (R3.2) |
| Exact restore | `MacWindow`, `exitMacOsNativeUnconventionalState` | remember parent/index/weight when moving into `MacosHiddenAppsWindowsContainer`; rebind there on exit |
| Auto-unhide | `GlobalObserver.onHideApp` | skip PIDs in the AeroSpace-hidden set |
| External activation | `GlobalObserver` `didUnhide`/`didActivate` | detect inactive-project PID → R4 policy |
| State | new small JSON state file | active project; read on start, written on switch |
| Events | `subscriptions.swift`, `ServerEvent` | `project-changed` |
| Router | separate repo/tool | out of AeroSpace.app |

## 7. Spikes (before implementation)

- **S1** ✅ Done (2026-10-22, macOS 27.0.1). `KERN_PROCARGS2` returns the full argv for same-user processes, no extra
  permissions needed:
  - Chrome via `open -na "Google Chrome" --args --user-data-dir=…` → argv contains `--user-data-dir=<absolute path>`.
  - kitty via `open -na kitty --args --single-instance --instance-group X` and via the binary directly → argv contains
    `--instance-group X`.
  - Personal Chrome / plain kitty → argv is just the executable path, so "no `--user-data-dir`" reliably means global.
  - Re-launch with the same `--instance-group` opens a new OS window inside the **existing** kitty process.
    Re-launch of Chrome with the same `--user-data-dir` + URL forwards the URL to the **existing** process (R6.3 holds).
- **S2** ✅ Done (2 test projects × {Chrome, kitty}, 5 windows, workspace on the 4K monitor):
  - **S2a, user config as is (`automatically-unhide-macos-hidden-apps = true`)**: every hide was reverted by
    `GlobalObserver.onHideApp` in < 25 ms; `isHidden` was never observed `true`. R3.6 is mandatory, not optional.
  - **S2b, auto-unhide off**: switching works. Windows move to `macos_native_window_of_hidden_app` and back.
    - Hiding API: `kAXHiddenAttribute` via AX works (~35–55 ms **per app**, serial). `NSRunningApplication.hide()`
      returns `false` but still takes effect, so its return value cannot be trusted; observe `isHidden` instead.
    - Latency (2 unhides + 2 hides, serial AX from an external process): 115–195 ms until the final state.
      Dominated by serial AX calls → in AeroSpace, issue them in parallel on the per-app AX threads.
    - Flicker: first switch had 2–6 re-layout jumps (last frame change ~160 ms after the windows appeared);
      in steady state 0 jumps, windows reappear directly at their final frames.
    - Exact restore (R3.3): stable across 3 round trips within one run, but an earlier run reordered the tiles
      (`chromeAnna, chromeBob, kittyBob, kittyAnna…` → `chromeAnna, kittyAnna…, kittyBob, chromeBob`): unhidden
      windows are re-inserted next to the MRU window. Confirms R3.3 is needed.
    - Windows of a project whose workspace is invisible stay parked in the corner on unhide (no stray windows).
  - Not yet measured: Firefox, native-fullscreen windows, overlap between "unhide target" and "hide others"
    (both sets visible for ~50–80 ms with serial calls).
- **S5** ✅ Cursor 3.26 (`com.todesktop.230313mzl4w4u92`) as a shared project app:
  - `--user-data-dir <dir>` gives a separate process per project, identifiable via `%{app-args}`.
    The CLI passes `--user-data-dir <dir>` (space), `open --args` passes whatever is written → match `--user-data-dir[= ]`.
  - Use the `cursor` CLI as the launch command: `cursor --user-data-dir ~/.cursor-projects/{project} <folder>` cold-starts
    the instance if needed, or opens the folder in the **running** instance of that dir (~1.3 s).
    Do **not** use `open -na Cursor` for an already running dir: it opened the folder but left a zombie process with an
    alert "Another instance of Cursor is running but not responding".
  - The data dir path must be short: Cursor puts its IPC socket into it and fails on startup when the socket path
    exceeds 103 chars.
  - Extensions are shared between instances (default `~/.cursor/extensions`) unless `--extensions-dir` is also passed.
    Settings, state and sign-in are per data dir (each instance signs in separately).
  - The personal Cursor (no `--user-data-dir`) stays global, same as Chrome.
- **S3** ✅ URL router (test app with a custom `s3test://` scheme, same `kAEGetURL` path as a default browser):
  - The sender PID is available in the event (`keySenderPIDAttr`) for `open`, `osascript open location` and
    `NSWorkspace.open` (the path Slack/Teams/Electron apps use).
  - Parent-chain walk works for plain shells: `open ← bash ← kitty[GUI, instance-group s3anna]`.
  - **Herdr panes are not children of kitty.** Pane processes are re-parented to launchd (ppid 1), so walking parents from
    an agent's `open` never reaches the project kitty. They inherit `HERDR_SOCKET_PATH` instead
    (`~/.config/herdr/sessions/<session>/herdr.sock` for named sessions), which is readable from another same-user process
    via `KERN_PROCARGS2` (exec-time env). → Router must check ancestors' env for the Herdr session too.
  - Race: when `open` exits before the router handles the event, the sender PID is gone. Seen 1 of 11 times,
    on the first event right after the router started; 0 of 10 with a warm router. → Needs a fallback.
  - The router app itself becomes frontmost on the event, so "frontmost app" is useless as a fallback;
    AeroSpace's focused window (the router has no windows) is the right one.
  - Not tested: Cmd-click inside kitty, links from Chrome/Slack (expected to behave like `NSWorkspace.open`).
- **S4** ✅ Herdr 0.9.5: the "workspace set" is a **named persistent session**. `herdr --session <name>` launches or
  attaches; each session has its own server and socket (`~/.config/herdr/sessions/<name>/`).
  - `kitty --single-instance --instance-group anna herdr --session anna` works; a second launch adds a window to the same
    kitty process attached to the same session.
  - Quitting the project kitty leaves the session running; relaunching re-attaches.
  - Window title is `"{hostname}: {workspace}"` (Herdr `window_title` config) and does not include the session name,
    which doesn't matter because ownership comes from the kitty `--instance-group`.
  - Herdr refuses to start nested when `HERDR_*` / `TERM_PROGRAM=herdr` are inherited. Launch commands run from
    AeroSpace's environment, so this does not apply; manual launch from inside a Herdr pane needs those vars unset.

## 8. Milestones

1. **M0** Spikes S1–S4.
2. **M1 Core** ✅: config + validation, `%{app-args}`/`%{app-project}`, ownership, `project` switching (R3), R4 `switch`/`rehide`,
   state persistence, `list-projects`, `project-changed`, tests, docs.
3. **M2 Lifecycle** ✅: `project-launch`, `autostart`, `--launch-missing`, `project-quit`, `move-app-to-project`.
   Plus: `bundle-id`, env variables for `on-project-changed`, `test … -- <rhs>`, `list-windows --project` alone.
4. **Per-window ownership** ✅ (§4a): `window-if`, `new-windows`, `on-window-assigned`, per-window hiding,
   R4 per window, `move-window-to-project`, per-window `project-launch`, exact order restore (`TilingChildrenOrder`).
5. **M3 Router**: URL router tool + `list-apps --pid`.

## 8a. Key map (user config, after M1/M2 land)

Leader `f20` / `ctrl-esc` enters `control` mode; one key acts, then back to `main` (existing style).

| Key | Command |
|---|---|
| `1` `2` `3` / `0` | `project anna` / `bob` / `company` / `project --none` |
| `` ` `` | `project-back-and-forth` |
| `` shift-` `` | `project-launch --app kitty` |
| `w` / `c` | `workspace w; project-launch --app chrome` / `workspace c; project-launch --app cursor` |
| `/` | `mode project`: `l` `project-launch`, `shift-q` `project-quit`, `shift-1/2/3` `move-app-to-project …`, `1/2/3` / `0` `move-window-to-project …` / `--none` |
| `h j k l` / `shift-h j k l` | `focus` / `move` direction |
| `z` / `b` | `fullscreen` / `balance-sizes` |
| `m` / `shift-m` | `focus-monitor --wrap-around next` / `move-node-to-monitor --focus-follows-window --wrap-around next` |

Unchanged: workspace letters (`x`, `shift-x`, `ctrl-x`), `f20` workspace back-and-forth, `tab` move workspace to monitor,
`f` stays "workspace f + Firefox" (activating Company's Firefox from another project switches to `company` per R4).

## 9. Later

- Per-project Slack instances.
- `peek` activation policy.
- Per-project workspace↔monitor restore (mostly unnecessary given D-3).
