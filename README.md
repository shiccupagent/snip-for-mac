# Snip for Mac

**Snip, mark up and record your screen. Free and open source.**

<p><a href="https://github.com/shiccupagent/snip-for-mac/releases/latest/download/Snip.dmg"><img alt="Download Snip for Mac" src="https://img.shields.io/badge/Download-Snip%20for%20Mac-0A84FF?style=for-the-badge&logo=apple&logoColor=white" height="48"></a></p>

Universal app for Apple Silicon and Intel Macs, macOS 14 or later.

Press **⌥⇧S**, drag over part of the screen, and it's already on your clipboard and open in an editor that's easy to draw on.
Press **⌥⇧R** to record the screen instead. If you've used the Snipping Tool on Windows, you'll feel at home.

- **Snip** a rectangle, a freeform shape, a window or the full screen, with an optional delay.
- **Mark up** with pen, highlighter, arrows, shapes, text, redact (pixelate) and crop. Every edit is copied automatically.
- **Copy text** out of any screenshot (on-device text recognition).
- **Record** an area with computer sound and microphone, then copy the video, share it, or turn it into a GIF in one click.
- **Edit recordings on a timeline**: trim the ends, split and cut out the middle, with a thumbnail strip, smooth
  scrubbing and undo. Saves straight into the file.
- **Let your AI edit for you**: a built-in MCP server and command line, so Claude, Gemini or any MCP app can watch a
  recording in seconds (labelled contact sheets) and trim or cut it. See [docs/AI-EDITING.md](docs/AI-EDITING.md).
- **Speedrun timer built in**: a LiveSplit-style timer (same colors and layout, reads and writes LiveSplit `.lss` splits)
  that sits in your recording, with global split keys that work while your game has focus.
- **AI-assisted split timing**: every speedrun recording saves its splits as JSON next to a clean copy of the video, so
  an AI with a terminal (Claude, Gemini, …) can scrub the video, fix the split times and redraw the timer.
  See [docs/SPEEDRUN-AI.md](docs/SPEEDRUN-AI.md).

## Install

1. Download **[Snip.dmg](https://github.com/shiccupagent/snip-for-mac/releases/latest/download/Snip.dmg)** (or from the [Releases page](https://github.com/shiccupagent/snip-for-mac/releases/latest)).
2. Open it and drag **Snip** into **Applications**.
3. Open Snip. macOS will say it can't verify the developer, because Snip isn't signed with a paid Apple developer
   account. Go to **System Settings → Privacy & Security**, scroll down and click **Open Anyway**.
   (Or run `xattr -dr com.apple.quarantine /Applications/Snip.app` in Terminal.)
4. Allow **Screen & System Audio Recording** when asked, then reopen Snip.

Requires macOS 14 (Sonoma) or later; the microphone during recordings needs macOS 15.

## Use it

| Shortcut | What it does |
| --- | --- |
| **⌥⇧S** | New snip: dims the screen with a bar at the top (Snip/Record · Rectangle · Freeform · Window · Full screen · ✕) |
| **⌥⇧R** | Record the screen. Pick an area, press **Start**, and press ⌥⇧R again (or the red menu bar icon) to stop. While recording, the controls fold into a small tab at the top of the screen: point at it to pause, stop or discard. The ⏲ button next to Start picks when recording begins: right away, or after 3, 5 or 10 seconds |
| **Esc** | Cancel |

You can change both shortcuts in **Settings**.

**After a snip:** it's already copied, so paste it anywhere, and it opens in the editor. A new snip takes the old editor's place; markup you never saved is kept as "… (marked up).png" next to the original. Prefer a small preview in the corner instead? Turn off **Open the editor right away** in Settings.

Every **New** button opens the bar in picture mode; press 🎥 on the bar to record instead (or use ⌥⇧R).

**Editor** (same layout as Snipping Tool):
- Top row: **＋ New**, 📷/🎥 (snip or record), mode, delay, then Undo / Redo, **Show File**, **Copy**, Share, and ⋯ (copy all text, Save As).
- Markup row: Pen, Highlighter, Eraser, Shapes (arrow, line, rectangle, oval), Text, Redact (pixelate), Crop, Copy text.
- Click a tool that's already selected to change its color and size.
- Hold **Shift** for straight lines, 45° angles and perfect squares.
- Every edit is copied to the clipboard automatically. ⌘C, ⌘Z and ⇧⌘Z work as usual; ⌘S shows the file.

**Recordings** save to `~/Movies/Snips`. Everything is saved as you go, with no Save step: **Show File** opens Finder with the file selected, ready to drag into YouTube, Discord or anywhere, without making copies. The video window also has **Copy** (paste the video into Messages, Slack or Mail), Share, and **GIF**, which makes a GIF and copies it.

**Timeline editor** (under every recording; for older ones use **Edit a Recording…** in the menu bar menu, or
right-click a video → Open With → Snip): drag across the thumbnails to scrub, then
- drag the yellow ends of the clip to trim it, or press **I** / **O** to trim to the playhead;
- **Split** (⌘B) at the playhead and **Delete** a piece to cut out the middle; cut-out parts turn dark;
- **Space** plays (skipping what you cut), **←/→** step a frame, **⇧←/→** a second, **⌘Z** undoes;
- **Save Edit** writes it into the video (the old version goes to the Trash). Speedrun splits show as flags you can
  drag, and the timer follows your cuts.

Snips save to `~/Pictures/Snips`.

**Let your AI edit your videos:** connect Snip to Claude Code, Claude Desktop or Gemini CLI with one line
(`claude mcp add snip -- /Applications/Snip.app/Contents/MacOS/Snip mcp`), then ask "cut the loading screens out of my
last recording". Setup and tools: [docs/AI-EDITING.md](docs/AI-EDITING.md).

**Speedrun timer (LiveSplit, built in):** on the record bar, set a delay and a 🏁 **Splits** button appears next to it. Turn it on and a LiveSplit-style timer (same colors and layout) sits in the top-right corner of the recorded area. It starts the moment the recording starts.
- Split keys work while your game has focus: **Num 1** split, **Num 2** skip, **Num 3** reset, **Num 5** pause, **Num 8** undo. Change them in Settings → Speedrun timer.
- Double-click the game, category or any split name on the timer to rename it in place (Enter saves, Esc cancels), even mid-run. ✏️ next to 🏁 opens the full splits editor. Right-click the timer for Open/Save Splits (LiveSplit `.lss` files, so splits move freely between Snip and LiveSplit).
- 👁 (or **Num 9**) hides the timer on your screen while you play, even mid-run. It's always drawn into the recording either way.
- **Let an AI fix your splits:** each speedrun recording also saves a copy without the timer and a `.speedrun.json` with every split's video time. Claude, Gemini or any AI with a terminal can scrub the video, correct the times, and run `snip speedrun render` to redraw the timer. See [docs/SPEEDRUN-AI.md](docs/SPEEDRUN-AI.md).
- Personal bests and best segments are saved when a run resets or the recording stops. Splits live in `~/Library/Application Support/Snip/Splits/`.

## Build from source

Swift Package, AppKit + SwiftUI + ScreenCaptureKit, no dependencies. Needs Xcode (the SwiftUI macros aren't in the
Command Line Tools alone):

```bash
swift build -c release --arch arm64 --arch x86_64 && bash scripts/bundle.sh
bash scripts/test_speedrun.sh   # speedrun timer + .lss + run-log tests (Command Line Tools are enough)
```

Every push to `main` builds a universal app on GitHub Actions and publishes it to the `latest` release. Without the
optional `SIGNING_P12_BASE64` / `SIGNING_P12_PASSWORD` secrets (a self-signed code-signing certificate), forks get
ad-hoc signed builds, which work but ask for Screen Recording permission again after each update.

## License

[MIT](LICENSE)
