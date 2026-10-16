# Let your AI edit your recordings

Snip has a built-in MCP server and command line, so an AI assistant (Claude, Gemini, or any app that
speaks MCP) can find your recordings, watch them in seconds, and trim or cut them for you.

Ask it things like:

- "Cut the loading screens out of my last recording."
- "Trim my newest recording to just the boss fight."
- "Find where I die in this run and cut everything after it."
- "Re-time my splits: split at each level's end screen." (speedrun recordings)

## Connect it

Snip must be in Applications. The server is the Snip app itself, started with `mcp`.

**Claude Code**

```bash
claude mcp add snip -- /Applications/Snip.app/Contents/MacOS/Snip mcp
```

**Claude Desktop**: Settings → Developer → Edit Config, then add to `claude_desktop_config.json`:

```json
{
  "mcpServers": {
    "snip": { "command": "/Applications/Snip.app/Contents/MacOS/Snip", "args": ["mcp"] }
  }
}
```

**Gemini CLI**: add the same `"snip"` entry under `"mcpServers"` in `~/.gemini/settings.json`.

Restart the app after editing its config.

## The tools

| Tool | What it does |
| --- | --- |
| `list_recordings` | Your recordings, newest first |
| `video_info` | Length, size, frame rate, sound tracks, speedrun files |
| `video_contact_sheet` | One image of evenly spaced frames, each labelled with its time (a whole video, or `from`/`to` a stretch) |
| `video_frame` | One exact frame |
| `video_edit` | `keep` stretches, `cut` stretches, `trim_start` / `trim_end`; `dry_run` to preview |
| `speedrun_get_log` / `speedrun_update_log` | Read and fix a speedrun's split times; the timer is redrawn ([format](SPEEDRUN-AI.md)) |

How an AI finds a moment fast: a contact sheet of the whole video (24 frames), then a sheet of just the
stretch where it happens (24 frames over a few seconds), then a single frame to confirm. Three looks
pin a moment to a fraction of a second, without playing anything.

Edits save into the recording, like **Save Edit** in Snip's timeline. The old version goes to the Trash,
so nothing is lost and no duplicates pile up. All times are seconds in the video as it is now; after a
cut, later times shift, so look again before a second edit.

## Command line

The same tools work in a terminal (`Snip` is `/Applications/Snip.app/Contents/MacOS/Snip`):

```bash
Snip video list
Snip video info "~/Movies/Snips/Recording 2026-10-15 at 22.51.32.mp4"
Snip video sheet "<video>" --from 1:00 --to 1:30 --count 24 --out sheet.jpg
Snip video frame "<video>" 1:12.4 --out frame.jpg
Snip video edit "<video>" --start 0:05 --cut 1:00-1:42 --end 3:30 --dry-run
Snip video edit "<video>" --keep 0:10-0:40 --keep 2:00-2:30
```

Times are seconds (`83.4`) or minutes:seconds (`1:23.4`); ranges are `start-end`. Speedrun recordings
also have `Snip speedrun list|show|render` ([guide](SPEEDRUN-AI.md)).
