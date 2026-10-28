# Screen Stitch

A small macOS app that records screen clips (a window, display or area) or collects ones you already have, then
combines them into one compressed MP4 with FFmpeg. It suits anyone who captures a demo or bug report in several takes
and wants to share a single small file.

## Requirements

- macOS 15 or later on Apple Silicon.
- [FFmpeg](https://ffmpeg.org), for example with [Homebrew](https://brew.sh): `brew install ffmpeg`.
- The app looks for `ffmpeg` and `ffprobe` in `/opt/homebrew/bin`, `/usr/local/bin`, `/opt/local/bin` and `/usr/bin`, in
  that order, and uses the first directory that has both. Without them it shows "FFmpeg isn't installed"; install
  FFmpeg, then reopen the app.

## Install

There's no download yet, so you build it on the Mac that will run it:

1. Install the Command Line Tools if you don't have them: `xcode-select --install`.
2. Install FFmpeg: `brew install ffmpeg`.
3. Build and install:

   ```sh
   git clone https://github.com/hobochili/screen-stitch.git
   cd screen-stitch
   ./build.sh --install
   ```

4. Open **Screen Stitch** from `~/Applications`. The first time you record, it asks for Screen Recording permission:
   click **Open System Settings**, turn Screen Stitch on, then click **Quit & Reopen**.

The first time, `./build.sh --install` asks whether to create a local signing certificate. Say yes if you plan to update
the app later, so Screen Recording permission survives updates (see [Signing](#signing-optional)).

## Update

```sh
cd screen-stitch
git pull
./build.sh --install
```

`--install` quits a running copy, installs the new one and reopens it. If a dialog or sheet is open, the app can't quit,
so the script stops after about 10 seconds. Close it and run the command again.

Without the signing certificate, macOS forgets the Screen Recording permission after an update. Remove the old Screen
Stitch entry under System Settings › Privacy & Security › Screen & System Audio Recording (select it, click
**−**), then grant it again when Screen Stitch asks.

## Use

The start screen leads with a large red **Record Screen** button, with **Watch for Recordings** and **Add Videos…**
below it. Once the list has a clip, a toolbar appears (**Record Microphone**, **Watch for
Recordings**, **Add Videos…**; hover an icon to see what it does), a header above the list has **Sort by Date** and
**Clear List…**, and the strip under the list offers **Record Another**.

### Record

1. Click **Record Screen**. The first time, the "Choose what to record" sheet shows thumbnails of your windows and
   displays. Pick one, or pick **Select Area** and drag out part of the screen (Esc cancels).
2. A floating bar says "Ready to record …" with a microphone toggle, **Change…**, **Cancel** and **Start**. The
   app's window hides, and if you picked a window, its app comes to the front so you can set it up. For an area, a
   dashed outline marks it until you stop. **Adjust…** lets you change it before you start: drag inside the area to
   move it or drag its edges to resize it, then press Return or click **Done**.
3. Click **Start**. The bar shows a timer and **Stop**.
4. Click **Stop**. The recording is added to the list and the app's window returns.

- The floating bar stays above other windows, and you can drag it by its label. A menu bar item mirrors it
  (**Start Recording**, then **Stop Recording**).
- While the list has clips, **Record Another** reuses the last window, display or area and goes straight to the floating
  bar. If that window or display is gone, the sheet opens instead, with a warning. Emptying the list or quitting
  forgets the last choice, so the start screen always opens the sheet.
- To pick something different, click **Change…** in the floating bar or **Record Something Else…** under the list.
- The Record menu has **Record Screen** (⌘R, which reuses the last choice while the list has clips and becomes
  **Stop Recording** while you record) and **Record Something Else…** (⇧⌘R).
- The microphone is off by default. To record your voice, turn on **Record Microphone** in the sheet or the floating bar
  before you click **Start**. The toolbar and Settings (⌘,) have the same setting. Only the microphone is recorded, not
  the sound your Mac plays.
- Recordings save to `~/Movies/Screen Stitch`. Change that from the start screen, the sheet or Settings (⌘,).
- The sheet needs Screen Recording permission to list windows and displays. Without it, a card explains how to grant it
  (**Open System Settings**, then **Quit & Reopen**) and offers **Use macOS Picker…**, which doesn't need permission.
  Recording starts as soon as you pick a window, app or display in the macOS picker. It can't record an area.

### Shortcuts from any app

While Screen Stitch is open, even hidden or in the background, these work from any app:

- **⌃⌥⌘R** steps through recording: it opens the floating bar (or the sheet, the first time), then starts, then stops.
- **⌃⌥⌘S** brings Screen Stitch to the front.

Turn them off in Settings (⌘,), which also says if another app already uses one. They don't open Screen Stitch when it
isn't running; for that, use the Shortcuts app's **Open App** action with a keyboard shortcut.

### Add existing clips

- To use recordings from the macOS Screenshot toolbar (press ⇧⌘5 to open it), click **Watch for Recordings**. It
  watches the folder the toolbar saves to (the "Save to" setting under Options; Desktop by default) and adds each new
  video as soon as it finishes. Videos already in the folder are ignored. **Choose Another Folder…** watches a
  different folder instead, and **Stop Watching** stops.
- Click **Add Videos…** (also File › Add Videos…, ⌘O), or drop video files on the window or the Dock icon. Files that
  aren't readable videos are skipped, with a warning.

### Combine

- The combined video follows the list from top to bottom. Drag rows to put them in any order (see [Order](#order)).
- Click a clip's thumbnail (or choose **Preview** from its right-click menu) to play it in a popover. Click outside the
  popover to close it. The right-click menu also has **Show in Finder** and **Remove from List**.
- Remove a clip with the ⓧ on its row, or empty the list with **Clear List…** in the header (it asks first). Neither
  deletes any files. Both are also in the File menu.
- Pick **Resolution** and **Quality**, click **Combine & Compress…** and choose where to save the MP4. The save panel
  starts in the first clip's folder, with the first clip's name plus "combined". **Cancel** stops the encode and deletes
  the partial file.
- When it finishes, the bottom bar shows the new file's size and how it compares with the original clips, with
  **Show in Finder**, **Open** and **Move Originals to Trash…**. The last one asks first, then moves the original
  clips to the Trash and removes them from the list.

## How it works

### Order

The combined video follows the list from top to bottom, and you can drag rows into any order.

To give you a sensible starting point, new clips are placed by when they were recorded. Recording time comes from the
QuickTime `creationdate` tag, then `creation_time`, then the file's creation date (or its modification date). Once
you've dragged a row, new clips go at the end instead, and **Sort by Date** in the header puts everything back in
recording order.

### Resolution and quality

- The largest clip sets the frame size. Every clip is scaled to fit it, and clips with a different shape are
  letterboxed.
- **Resolution** (Original, 1440p, 1080p or 720p) caps the shorter side of that frame and never makes it bigger than
  the largest clip. 1080p turns a 3456×2234 Retina recording into 1670×1080. The summary in the bottom bar shows the
  result ("Output 1670×1080"). The default is 1080p.
- **Quality** is the x264 CRF: High 20, Standard 23 (the default), Smaller File 28.

### Output

- MP4 with H.264 video and AAC audio (128 kbps, 48 kHz stereo), written with `+faststart`.
- Variable frame rate is kept, so static stretches cost almost nothing.
- If any clip has audio, clips without it get silence. If none do, the output has no audio track.
- Clips with several audio tracks are mixed into one.

## Build

```sh
./build.sh                          # → build/Screen Stitch.app
./build.sh --install                # also installs it into ~/Applications, quitting and reopening a running copy
./build.sh --install /Applications  # or into another folder
```

Building needs only the Command Line Tools (`xcode-select --install`); full Xcode isn't required. The Command Line
Tools don't ship the SwiftUI macro plugin, so the code avoids `@State` and keeps view state on the `@Observable` model.

### Signing (optional)

By default `build.sh` signs the app ad hoc. That works, but macOS ties Screen Recording and microphone permission to
the signature, so it asks again after every rebuild. `./make-signing-cert.sh` adds a self-signed "Screen Stitch Local
Signing" certificate to your login keychain, and `build.sh` signs with it from then on, so rebuilds keep their
permissions.

`./build.sh --install` offers to run it when you run it from a terminal and the certificate is missing. If you say no,
it remembers that in `.no-signing-cert` and doesn't ask again. Delete that file to be asked again, or run
`./make-signing-cert.sh` any time.

The app isn't notarized, so a copy built on one Mac and moved to another is blocked on first launch. Allow it under
System Settings › Privacy & Security › **Open Anyway**, or build it on that Mac instead.

## Command line

The same binary runs without a window:

```sh
"$HOME/Applications/Screen Stitch.app/Contents/MacOS/ScreenStitch" --cli \
  [--size original|1440|1080|720] [--quality high|standard|small] OUTPUT.mp4 INPUT...
```

- `--size` defaults to 1080 and `--quality` to standard (`small` is the **Smaller File** setting).
- Inputs are sorted by recording time (see [Order](#order)), whatever order you list them in. Unreadable inputs are
  skipped.
- An existing `OUTPUT.mp4` is overwritten.
- The path above is where `./build.sh --install` puts the app by default. For a plain `./build.sh`, use
  `build/Screen Stitch.app/Contents/MacOS/ScreenStitch`.
