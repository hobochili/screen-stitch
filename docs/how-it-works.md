# How it works

[Order](#order) · [Resolution and quality](#resolution-and-quality) · [Output](#output) ·
[Command line](#command-line)

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

**Combine Without Compressing…** copies each clip's video and audio as they are (H.264 or HEVC, with AAC) into an MP4,
so none of this applies to it.

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
- The path above is where `./build.sh --install` puts the app by default. For a plain `./build.sh`, use
  `build/Screen Stitch.app/Contents/MacOS/ScreenStitch`.
