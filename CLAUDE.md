# Snip: agent notes

Menu bar screenshot + screen-recording app for macOS 14+, modelled on Windows' Snipping Tool
(capture bar, instant clipboard copy, two-row markup editor). Swift Package, AppKit + SwiftUI,
ScreenCaptureKit. User-facing docs: README.md.

## Build and test loop
- Without full Xcode, local `swift build` fails: the Command Line Tools lack SwiftUI's macro plugin
  (`@State` → "plugin for module 'SwiftUIMacros' not found"). Then CI is the compiler.
- Loop: commit → `git push` → `bash scripts/try_latest.sh` (waits for the ~40 s CI build of HEAD,
  installs it to /Applications/Snip.app, relaunches). Don't run it while someone is mid-test:
  it quits the running Snip.
- Every push to `main` replaces the `latest` release (Snip.dmg + Snip.zip) that users install from.

## Signing and permissions
- CI signs with the self-signed "Snip Self-Signed" cert (secrets SIGNING_P12_BASE64/PASSWORD).
  The stable cert keeps the Screen Recording grant across updates; never switch to ad-hoc signing.
- Screen Recording is first requested on the first capture (`Permission.ensureScreenRecording`).
  Granting it is a System Settings change: the user does it, agents never do.

## Testing on the real Mac
- Trigger a snip: `osascript -e 'tell application "System Events" to keystroke "s" using {option down, shift down}'`.
- Why did the overlay close? `log show --last 5m --predicate 'subsystem == "com.shiccup.snip"'` logs every open/cancel with its reason.
  Don't judge from CGWindowList on-screen polling: it drops the overlay while it's still up.
- A Dock pin must point at /Applications/Snip.app (a pin to a deleted copy silently does nothing).
- Snips save to ~/Pictures/Snips, recordings to ~/Movies/Snips; check the clipboard with `osascript -e 'clipboard info'`.
- Someone may be watching or using the screen: keep overlay pokes short, close them, and check idle time first.

## Speedrun timer (Sources/Snip/Speedrun)
- LiveSplit rebuilt in-app: `SpeedrunTimer` (rules), `Splits` (.lss read/write, edits in place to keep unknown XML),
  `TimerView` (LiveSplit default colors), `SpeedrunController` (panel, keys, menu), `SplitsEditorWindow`.
- `bash scripts/test_speedrun.sh` tests rules + .lss with only the CLT (also runs in CI). Keep test timings generous.
- The timer window is never captured: `TimerOverlay` (rendered at 30 fps where the window sits) is composited into
  each frame by `Recorder` (idle frames redrawn), so 👁/Num 9 can hide it on screen mid-run.
- Each speedrun recording also writes "(no timer).mp4" + `.speedrun.json` (`RunLog`); `Snip speedrun list|show|render`
  (`SpeedrunCLI`, entry in SnipMain) replays the log on video time (`RunReplay`) and redraws. AI guide: docs/SPEEDRUN-AI.md.
  `~/.local/bin/snip` links to the app binary on this Mac. Offline-test render with an ffmpeg testsrc clip + hand-written log.
- Drive tests with CGEvent (computer-use can't see Snip, an accessory app). Stop if someone is using the screen.

## Repo
- Public, MIT. No Co-Authored-By trailers. Never commit personal info, keys or certificates.
