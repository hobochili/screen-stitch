# Screen Stitch

A small macOS app that records screen clips (a window, display or area) or collects ones you already have, then
combines them into one compressed MP4 with FFmpeg. It suits anyone who captures a demo or bug report in several takes
and wants to share a single small file.

## Requirements

- macOS 15 or later on Apple Silicon.
- [FFmpeg](https://ffmpeg.org), for example with [Homebrew](https://brew.sh): `brew install ffmpeg`.
- The app looks for `ffmpeg` and `ffprobe` in `/opt/homebrew/bin`, `/usr/local/bin`, `/opt/local/bin` and `/usr/bin`, in
  that order, and uses the first directory that has both. Without them it shows "FFmpeg isn't installed"; install
  FFmpeg, then click **Quit & Reopen**.

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

4. Open Screen Stitch from `~/Applications`. The first time you record, it asks for Screen Recording permission: click
   **Open System Settings**, turn Screen Stitch on, then click **Quit & Reopen**.

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
**−**), then grant it again when Screen Stitch asks. If you also turned on Screen Stitch under Accessibility (Device
Control and Data Access in macOS 27), remove its entry there too; macOS forgets that permission as well. To turn it
back on, click **Bring to Front** when another window covers the one you picked.

## Use

A session is the clips you record or add, plus the video you save from them (the combined video, or a compressed copy
if there's only one clip). **Clear Session** empties the list so you can start a new one. It keeps your files unless
you choose to move them to the Trash.

The start screen leads with a large red **Record Screen** button, with **Watch for Recordings** and **Add Videos…**
below it. Once the list has a clip, a toolbar appears (**Record Microphone**, **Watch for Recordings** and
**Add Videos…**; hover an icon to see what it does). A header above the list shows "Session · 3 clips" and has
**Title Cards**, **Sort by Date** and **Clear Session**. The strip under the list has a red **Record Another** button
with an arrow for **Record Something Else…** (it's a plain **Record Screen** button until you've made a recording).

### Record

1. Click **Record Screen**. The "Choose what to record" sheet shows thumbnails of your windows and displays. Pick one,
   or pick **Select Area** and drag out part of the screen (Esc cancels). Windows that are minimized, hidden or on
   another desktop are listed under **Not on Screen**; picking one tries to bring it back.
2. The floating bar appears at the top of the display that has what you picked. It says "Ready to record" and what you
   picked, with "Not recording yet. Click Start to begin." under it, and has a microphone button, **Change…**,
   **Cancel** and **Start**. The app's window hides, and if you picked a window, its app comes to the front so you can
   set it up. A dashed outline marks what will be recorded and follows a window if it moves. If there's room below the
   window, a second red **Start** button sits centered under it. A window that fills the screen doesn't get one, and
   neither does a display. An area stays editable until you start: drag inside it to move it, or drag an edge or corner
   to resize it. It stays on its display and can't be made very small. Below it (or just inside its bottom edge, if the
   screen ends there), a dark label shows its size (for example "680×340") next to a red **Start** button. These
   **Start** buttons work like the one in the bar. While the area is editable, a click inside it moves the area rather
   than reaching the app underneath; outside it, your apps work as usual.
3. Click **Start**. What you're recording dims slightly, and a translucent panel appears in the middle with a
   clapperboard, its stick open, and "Recording" and the number the new clip will have in the list ("Clip 3") under it.
   The stick snaps shut the moment recording begins, a fraction of a second later, and the panel fades out about a
   second after that. (With Reduce Motion on, the stick stays shut.) The floating bar turns solid red and shows **REC**
   with the time, and the outline becomes a red frame. An area locks when you click **Start** (or when a countdown
   begins), and clicks inside it reach your apps again. The **Start** below a window or area becomes the time and a
   **Stop** button; an area with no room below gets them just inside its bottom edge. None of these appear in the
   recording.
4. Click **Stop**, in the floating bar or next to the window or area you're recording. The recording is added to the
   list as a clip and the app's window returns.

- The floating bar stays above other windows, and you can drag it by its label. While it's up, a menu bar item mirrors
  it (**Start Recording**, then "Stop · 0:42" with the elapsed time), and the Dock icon shows a **REC** badge while you
  record.
- Settings (⌘,) has two options for how recording starts. **Briefly show “Recording” when recording starts** (on by
  default) lets you turn the panel off. **Count down 3-2-1 before recording** (off by default) adds a countdown after
  you click **Start**: the bar says "Recording starts in 3…", a large number shows on screen, and **Cancel** stops it
  (an area becomes editable again). Neither appears in the recording.
- A window's size is read when recording starts, so resizing or restoring the window after you pick it is fine. If you
  resize it during the recording, the clip keeps the size it started with. A smaller window stays the same scale and is
  centered with black bars around it; a bigger one is scaled down to fit.
- If the window you picked isn't on screen, the bar asks you to click the app's icon in the Dock (or the window itself
  there, if it's minimized), and **Start** won't record until it's back.
- Before you click **Start**, if another window covers the one you picked, the bar says so and shows
  **Bring to Front**. Bringing one particular window forward needs Accessibility permission. Until it's on, each click
  on **Bring to Front** opens the page in System Settings where you turn Screen Stitch on: Privacy & Security ›
  Accessibility, or Device Control and Data Access in macOS 27. (macOS shows its own prompt only the first time.) No
  relaunch is needed. Once it's on, picking a window brings that exact window to the front (restoring it if it's
  minimized), and **Bring to Front** does the same.
  Neither can reach a window on another desktop. Without the permission, Screen Stitch can only bring the app forward,
  so a different window of the same app can end up in front. A covered window still records normally.
- Before recording starts, Screen Stitch takes Esc from whatever app is in front: in the area selector it closes the
  selector, in the floating bar it cancels, and during a countdown it returns to the floating bar. Once you're
  recording, Esc goes to the app you're recording as usual. **Use from any app** in Settings (⌘,) turns this off too.
- While the list has clips, **Record Another** reuses the last window, display or area and goes straight to the
  floating bar (an area is editable again). "Same as last time" next to it names that choice; for a window, it shows
  the app's icon and the window's title, and hovering shows the app's name and the full title. If that window or
  display is gone, the sheet opens instead, with a warning. Emptying the list (for example with **Clear Session**) or
  quitting forgets the last choice, so the start screen always opens the sheet.
- To pick something different, click **Change…** in the floating bar, or click the arrow on the right of
  **Record Another** and choose **Record Something Else…**.
- The Record menu has **Record Screen** (⌘R, which reuses the last choice while the list has clips and becomes
  **Stop Recording** while you record) and **Record Something Else…** (⇧⌘R).
- The microphone is off by default, and the setting is remembered. To record your voice, turn on **Record Microphone**
  in the sheet, or click the microphone button in the floating bar, before you click **Start**. The toolbar and Settings
  (⌘,) have the same setting. Only the microphone is recorded, not the sound your Mac plays.
- By default, recordings save to Movies › Screen Stitch (`~/Movies/Screen Stitch`). On the start screen and in the
  sheet, click the folder path for **Show in Finder** and **Change Folder…**. Settings (⌘,) has both too (**Change…**
  there), plus **Use Default** once you've changed the folder.
- The sheet needs Screen Recording permission to list windows and displays. Without it, a card explains how to grant it
  (**Open System Settings**, then **Quit & Reopen**) and offers **Use macOS Picker…**, which doesn't need permission.
  Recording starts as soon as you pick a window, app or display in the macOS picker, with no countdown or "Recording"
  panel. It can't record an area.

### Shortcuts from any app

While Screen Stitch is open, even hidden or in the background, these shortcuts work from any app:

- **⌃⌥R** (Control-Option-R) steps through recording: it opens the floating bar (or the sheet, if there's no last
  choice to reuse), then starts, then stops. During a countdown it cancels.
- **⌃⌥S** brings Screen Stitch to the front.

To change one, open Settings (⌘,), click the shortcut and press the keys you want (Esc cancels). A shortcut needs at
least two of ⌃ ⌥ ⇧ ⌘ plus a key, so it doesn't take over a common command. A function key (F1–F20) works with or without
them. **Use Defaults**, shown once you change one, puts both back.

If macOS or another app already uses the keys, Settings says so in red and the shortcut won't work. macOS's own
shortcuts always win, so to use one of them, such as ⇧⌘5 for the screenshot toolbar, first turn it off:
**Open Keyboard Settings…** opens System Settings › Keyboard, where **Keyboard Shortcuts…** lists them. Settings
can't see shortcuts that only work inside another app's menus.

Turn the shortcuts off with **Use from any app**. They don't open Screen Stitch when it isn't running; for that, use the
Shortcuts app's **Open App** action with a keyboard shortcut.

### Add existing clips

- To use recordings from the macOS Screenshot toolbar (press ⇧⌘5 to open it), click **Watch for Recordings**. It
  watches the folder the toolbar saves to (the "Save to" setting under Options; Desktop by default) and adds each new
  video as soon as it finishes. Videos already in the folder are ignored. While it watches, the bottom bar has
  **Change…** to watch a different folder and **Stop Watching**.
- Click **Add Videos…** (also File › **Add Videos…**, ⌘O), or drop video files on the window or the Dock icon. Files
  that aren't readable videos are skipped, with a warning.

### Combine

- Drag rows to put the clips in any order. The combined video follows the list from top to bottom (see
  [Order](#order)).
- Click a clip's thumbnail (or choose **Preview** from its right-click menu) to select it and play it in Quick Look,
  the macOS preview window, which you can resize or make full screen. The right-click menu also has **Show in Finder**
  and **Remove from List**.
- Thumbnails are cropped to fill their box, so they can leave out a clip's edges. Quick Look shows the whole clip.
- Click a row to select it (⌘-click or ⇧-click selects several; ↑ and ↓ move the selection). Press Space (anywhere in
  the window except a text field) to open the selected rows in Quick Look, as in the Finder, or the first row if nothing
  is selected. A title card shows as a picture of the card. While Quick Look is open, clicking another row or pressing ↑
  or ↓ switches to it; Space closes it.
- Remove a clip with the ⓧ on its row. That doesn't delete its file.
- To add text between clips, use **Title Cards** in the list header. **Before & After** (shown when the list has exactly
  two clips, or when it's already on) puts "Before…" above the first clip and "After…" between them, for showing a
  change, and has a checkmark while on. Choose it again to remove just those two cards. **Add Title Card** adds one
  after the selected row (or at the end); turning off **Before & After** doesn't remove it. A title card is a row you
  can drag like a clip. Type its text, set how long it shows in seconds (type a number or use the arrows; 0.25 to 10,
  new cards start at 1.25) and choose **Dark** (white text on black) or **Light** (black text on white). Remove one with
  its ⓧ. In the combined video it fills the frame with large centered text in New York, Apple's serif font, and has no
  sound. Title cards aren't files, so **Clear Session** removes them too, and while the list has any, **Combine Without
  Compressing…** isn't offered.
- Pick **Resolution** and **Quality**, click **Combine & Compress…** and choose where to save the MP4. The save panel
  starts in the first clip's folder, with the first clip's name plus "combined". With a single clip, the button says
  **Compress…** and the name gets "compressed" instead. While it works, **Cancel** stops it and deletes the partial
  file.
- When there are two or more clips and every one has the same size and format, an arrow appears next to
  **Combine & Compress…**. Its menu has **Combine Without Compressing…**, which joins the clips as they are. It's much
  faster and loses no quality, but the file stays about as big as the clips put together, and **Resolution** and
  **Quality** don't apply. Recordings of the same window or area at the same size usually qualify, as long as all have
  the microphone on or all have it off. If there's no arrow, the clips differ in size or format, or the list has title
  cards.
- When it finishes, the bottom bar shows a thumbnail of the saved video, its file name and size, and how much smaller
  (or larger) it is than the original clips, with **Show in Finder**, **Open** and **Clear Session**. Click the
  thumbnail to play the saved video in Quick Look.
- To start a new session, click **Clear Session** (in the list header, or in the bottom bar once the video is saved) or
  choose File › **Clear Session** (⌘N). It asks what to do with the session's files. Every choice except **Cancel**
  then empties the list and takes you back to the start screen:
  - **Keep Files** (the default, so Return picks it) leaves every file where it is.
  - **Move Clips to Trash** moves every clip in the list, including any you added with **Add Videos…**, dropped on
    the window or the Dock icon, or opened from the Finder. The dialog says how many you added from elsewhere: clips
    you recorded in Screen Stitch or that **Watch for Recordings** picked up count as made in this session.
  - **Move Everything to Trash** moves those clips and also any combined video you made in this session that's still
    where you saved it (both, if you combined twice). It only appears when there is one.
  - **Cancel** (or Esc) leaves the session as it is.

  Nothing else is touched, even in the same folder, and anything moved to the Trash can be put back from there. When
  it's done, a note says how many files were moved, or which ones couldn't be. If you haven't saved a video from the
  clips yet, the dialog says so.

## How it works

### Order

New clips are placed by when they were recorded, which gives the list a sensible starting order. Recording time comes
from the QuickTime `creationdate` tag, then `creation_time`, then the file's creation date (or its modification date).
Once you've dragged a row, new clips go at the end instead, and **Sort by Date** in the header puts the clips back in
recording order. It moves only the clips; title cards stay in their places.

### Resolution and quality

These apply to **Combine & Compress…** and **Compress…**, not to **Combine Without Compressing…**.

- The frame is as wide as the widest clip and as tall as the tallest. Clips aren't enlarged, so text stays the same size
  from clip to clip, and a smaller clip or one with a different shape (for example, a window you made narrower between
  recordings) is centered with black bars around it in the combined video. The original files aren't changed.
- **Resolution** (Original, 1440p, 1080p or 720p) caps the shorter side of that frame. If the frame is bigger than the
  cap, every clip is scaled down by the same amount. 1080p turns a 3456×2234 Retina recording into 1670×1080. The
  summary in the bottom bar shows the result ("Output 1670×1080"). The default is 1080p.
- **Quality** is the x264 CRF: High 20, Standard 23 (the default), Smaller File 28.

### Output

**Combine Without Compressing…** copies each clip's video and audio as they are (H.264 or HEVC, AAC) into an MP4, so
the notes below don't apply to it.

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

By default `build.sh` signs the app ad hoc. That works, but macOS ties Screen Recording, Accessibility and microphone
permission to the signature, so it asks again after every rebuild. `./make-signing-cert.sh` adds a self-signed
"Screen Stitch Local Signing" certificate to your login keychain, and `build.sh` signs with it from then on, so
rebuilds keep their permissions.

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
