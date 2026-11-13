# How it works

[Order](#order) · [Resolution and quality](#resolution-and-quality) · [Output](#output) ·
[Export queue](#export-queue) · [Saved session](#saved-session) · [Command line](#command-line)

## Order

New clips are placed by when they were recorded, which gives the list a sensible starting order. Screen Stitch reads
the recording time from the file's QuickTime `creationdate` tag. If that's missing, it falls back to `creation_time`,
then the file's creation date, then its modification date.

Once you've dragged a row, new clips go at the end instead. **Sort by Date** puts the clips back in recording order. It
moves only the clips, and title cards stay where they are.

## Resolution and quality

These apply to **Combine & Compress…** and **Compress…**, not to **Combine Without Compressing…**.

The video frame is as wide as the widest clip and as tall as the tallest. Clips aren't enlarged, so text stays the same
size from clip to clip. A smaller clip, or one with a different shape (for example, a window you made narrower between
recordings), is centered with black bars around it. The original files aren't changed.

**Resolution** caps the shorter side of that frame. If the frame is bigger than the cap, every clip is scaled down by
the same amount. The bottom bar shows the result, for example "Output 1670×1080".

| Resolution | Shorter side | A 3456×2234 Retina recording becomes |
| :--- | :--- | :--- |
| Original | Unchanged | 3456×2234 |
| 1440p | At most 1440 | 2228×1440 |
| **1080p** (the default) | At most 1080 | 1670×1080 |
| 720p | At most 720 | 1114×720 |

**Quality** sets the constant rate factor (CRF) of the x264 encoder. A lower number keeps more detail and makes a
bigger file.

| Quality | CRF |
| :--- | :--- |
| High | 20 |
| **Standard** (the default) | 23 |
| Smaller File | 28 |

## Output

**Combine & Compress…** and **Compress…** write an MP4 with these properties:

- H.264 video and AAC audio (128 kbps, 48 kHz stereo).
- `+faststart`, so the video can start playing before it's fully downloaded.
- The variable frame rate is kept, so stretches where nothing moves cost almost nothing.
- If any clip has audio, clips without it get silence. If none do, the video has no audio track.
- A clip with several audio tracks has them mixed into one.

Text to redact is found before FFmpeg starts. Screen Stitch splits each clip into 20-second chunks and hands them to up
to 8 worker processes, the app run again with `--find-text`. Each worker reads a frame carefully every half second and
whenever the picture changes a lot, and quickly in the frames between. Vision misses small text in a big frame, so a
careful reading splits a frame more than 800 pixels across or high into overlapping tiles, each at most 800 pixels or
half its longer side. Every reading reads again only the parts of the frame that changed since they were last read, and
what it found counts as still there for as long as the pixels under it stay the same. Then the frames where text went
missing are read again carefully, around where it was seen, until nothing new turns up. The places are kept per text in
`~/Library/Caches/Screen Stitch/Redactions`, so a relaunch doesn't search again. The cache key includes a version
number, and a clip is searched again if its file changes. Rotated video isn't searched, and combining stops with a
message. Only clips where text was found are rewritten, using AVFoundation. A box stays up through frames where its text
went unread, and starts half a second early, or up to 10 seconds early for text that sat still, but only where the
picture matches the text as it was read. Text that jumps between two readings, as a page does when scrolled a notch,
gets one box over both places until the second. The boxes are drawn into the decoded frames before they're re-encoded,
so no original pixels remain under them. They can't be recovered from the saved video. The sound is copied as it is.
FFmpeg then compresses those copies like any other clip, and Screen Stitch deletes them afterwards. The original clips
are never modified.

**Combine Without Compressing…** copies each clip's video and audio as they are (H.264 or HEVC, with AAC) into an MP4,
so none of this applies to it. With text to redact, it's offered only once the search shows the text isn't in any clip,
since the boxes have to be drawn into the video.

## Export queue

**Combine & Compress…**, **Compress…** and **Combine Without Compressing…** each add an export to a queue. An export
holds a snapshot of the list: the clips and title cards in order, the size and quality, and the checked text to redact.
Later changes to the list don't affect it. Exports run one at a time, oldest first, so each has the whole Mac. An export
that needs text searched also waits for that search, and searches for waiting exports run before the session's own.

Clips a running or waiting export reads from can't be moved to the Trash, and **Clear Session** leaves them alone. A
finished export is added to the session's saved videos only if the session hasn't been cleared since it started.

While you record, searches and FFmpeg don't pause. They move into macOS's background priority band, which runs them at
low priority, mostly on the efficiency cores and with their disk use throttled. They finish later but leave the
recording what it needs, and they move back out when it stops.

The Export Log keeps the last 3000 lines of what searches and exports did, in memory only. It's empty after a relaunch.

## Saved session

Screen Stitch writes the session to `~/Library/Application Support/Screen Stitch/session.json` whenever it changes, and
reads it back on the next launch. It holds the clip list in order, the title cards with their text, length and
style, whether you've reordered by hand (see [Order](#order)), which clips were recorded in the session and the videos
saved from it, with the text each one redacted and where. The list of text to redact isn't in this file. It's kept in
the app's settings. Clips are files, so only their paths are saved. Each is read again on launch, and any that were
moved, deleted or can't be read are left out with a warning. **Clear Session** empties the file.

## Command line

The same app runs without a window:

```sh
"$HOME/Applications/Screen Stitch.app/Contents/MacOS/ScreenStitch" --cli \
  [--size original|1440|1080|720] [--quality high|standard|small] OUTPUT.mp4 INPUT...
```

- `--size` defaults to `1080` and `--quality` to `standard`. `small` is the **Smaller File** setting.
- Inputs are combined in recording order (see [Order](#order)), whatever order you list them in. Unreadable inputs are
  skipped.
- An existing `OUTPUT.mp4` is overwritten.
- Text redaction isn't available here. The command line never redacts text.
- The path above is where `./build.sh --install` puts the app by default. For a plain `./build.sh`, use
  `build/Screen Stitch.app/Contents/MacOS/ScreenStitch`.
