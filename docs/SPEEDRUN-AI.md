# Re-timing a speedrun recording (for AIs)

When Snip records with the speedrun timer on, it saves three files in the recordings folder
(`~/Movies/Snips` by default):

| File | What it is |
| --- | --- |
| `Recording ….mp4` | The video with the timer drawn in |
| `Recording … (no timer).mp4` | The same video without the timer. **Scrub this one** |
| `Recording ….speedrun.json` | The runs: when the clock started, every split, pauses. **Edit this one** |

The command line tool is the Snip app itself:

```bash
snip speedrun list                     # recordings with a speedrun, newest first
snip speedrun show "<recording>.mp4"   # runs, split video times, clock times, +/- vs PB
snip speedrun render "<recording>.mp4" # redraw the timer from the .speedrun.json
```

`snip` is a link to `/Applications/Snip.app/Contents/MacOS/Snip` (use that path if `snip` isn't on PATH).

## Workflow

1. `snip speedrun show "<recording>.mp4"` to see the runs and where each split is now.
2. Scrub the clean copy to find the exact moment of each split (level end, boss kill, …), e.g. one frame per
   second as a contact sheet, then frame-exact around the moment:
   ```bash
   ffmpeg -v error -i "<recording> (no timer).mp4" -vf "fps=1,scale=480:-1,tile=6x5" -frames:v 1 sheet.png
   ffmpeg -v error -ss 83 -i "<recording> (no timer).mp4" -t 2 -vf "fps=30,scale=480:-1,tile=6x10" -frames:v 1 zoom.png
   ```
3. Edit the `.speedrun.json` (format below): set each segment's `split` to the video time in seconds.
4. `snip speedrun render "<recording>.mp4"`. The old timed video goes to the Trash; the clean copy and the log stay,
   so you can fix and render again as often as needed.
5. Check a frame of the result.

## .speedrun.json

```json
{
  "version": 1,
  "video": "Recording 2026-10-15 at 22.12.32.mp4",
  "clean_video": "Recording 2026-10-15 at 22.12.32 (no timer).mp4",
  "game": "Test Game", "category": "Any%",
  "offset": 0,
  "timer": { "x": 532, "y": 8, "scale": 2, "opacity": 0.8 },
  "runs": [
    {
      "attempt": 5,
      "start": 0.42,
      "segments": [
        { "name": "Level 1", "split": 12.31, "pb": 2.5, "best": 2.2 },
        { "name": "Level 2", "split": null,  "pb": 5.0, "best": 2.4 },
        { "name": "Boss",    "split": 40.07, "pb": 9.0, "best": 3.8 }
      ],
      "pauses": [[20.0, 25.5]],
      "reset": null
    }
  ]
}
```

- Video times (`start`, `split`, `pauses`, `reset`) are **seconds into the video**. Change these.
- `start`: when the clock starts (it shows `offset`, usually 0.00). `split: null` = skipped or not reached.
- `pauses`: ranges the clock was stopped. `reset`: when the attempt was abandoned (`null` = it ran to the end,
  or finished at its last split).
- `pb` / `best`: the comparison (personal-best split times and best segments, in clock seconds) as it was when
  the run started. They colour the deltas; leave them unless asked.
- `game`, `category` and segment `name`s are drawn on the timer: fix typos here too.
- `timer`: where the timer sits, top-left in points from the video's top-left; `scale` = video pixels per point; `opacity` (optional, 0.2–1) how solid it is drawn.
- Several attempts in one recording are several entries in `runs`.
