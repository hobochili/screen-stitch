# User guide

[Recording](#recording) · [Shortcuts](#shortcuts) · [Adding clips](#adding-clips-you-already-have) ·
[Arranging clips](#arranging-clips) · [Title cards](#title-cards) · [Combining](#combining) ·
[Starting over](#starting-over) · [Troubleshooting](#troubleshooting)

A **session** is the clips in the list plus the video you save from them. Record or add clips, put them in order, then
combine them. When you're done, click **Clear Session** to start the next one.

Before you have any clips, the window shows a big red **Record Screen** button, with **Watch for Recordings** and
**Add Videos…** below it. After that, it shows the list of clips. **Title Cards**, **Sort by Date** and
**Clear Session** are in the header above the list, and **Record Another** is just below it. The bottom bar, along the
bottom of the window, is where you choose **Resolution** and **Quality** and combine the clips. The toolbar at the top
has **Record Microphone**, **Watch for Recordings** and **Add Videos…**.

## Recording

### Pick what to record

Click **Record Screen** (⌘R). The "Choose what to record" sheet shows your windows and displays. Pick one, or choose
**Select Area** and drag out part of the screen (Esc cancels). Windows that are minimized, hidden or on another desktop
are listed under **Not on Screen**, and picking one tries to bring it back.

### Get ready

Screen Stitch's window hides and a floating bar appears at the top of the screen, saying what you're about to record. A
dashed outline shows exactly what will be recorded. If you picked a window, its app comes to the front so you can set
it up.

- The bar has a **Start** button. An area has one below it too, and so does a window when there's room.
- You can still move and resize an area: drag inside it, or drag an edge or corner.
- **Change…** picks something else, and **Cancel** (or Esc) backs out.
- Drag the bar by its label to move it.
- The microphone button turns your voice on or off.

### Record

Click **Start**. A clapperboard flashes up to mark the start, the bar turns red and shows the elapsed time, and the
outline becomes a red frame. When you're done, click **Stop**, either in the bar or next to the window or area you're
recording. The clip is added to the list and Screen Stitch comes back.

The bar, the outline, the buttons and the clapperboard don't appear in the recording. While you record, the menu bar
also shows the elapsed time ("Stop · 0:42") and the Dock icon shows **REC**.

> [!TIP]
> To skip the clapperboard, turn off **Briefly show “Recording” when recording starts** in Settings (⌘,).

If you resize the window during the recording, the clip keeps the size it started with. A window that gets smaller is
centered with black bars around it, and one that gets bigger is scaled down to fit.

### Record another take

Once the list has clips, **Record Another** reuses the last window, display or area and goes straight to the floating
bar. "Same as last time" next to the button shows what it will reuse. To record something else, click the arrow on
**Record Another** and choose **Record Something Else…** (⇧⌘R), or click **Change…** in the floating bar.

If that window or display is gone, the sheet opens instead. Clearing the session or quitting forgets the last choice, so
the next recording starts at the sheet.

### Microphone

The microphone is off by default, and Screen Stitch remembers your choice. Turn on **Record Microphone** in the sheet,
in Settings or in the toolbar (once you have a clip), or click the microphone in the floating bar before you start. Only
your voice is recorded, not the sound your Mac plays.

### Where recordings go

Recordings save to `~/Movies/Screen Stitch` unless you change it. Click the folder path on the start screen or in the
sheet to **Show in Finder** or **Change Folder…**. Settings has both too, plus **Use Default** once you've changed the
folder.

## Shortcuts

| Shortcut | What it does |
| :--- | :--- |
| ⌃⌥R | From any app: each press opens the floating bar, then starts recording, then stops it |
| ⌃⌥S | From any app: brings Screen Stitch to the front |
| Esc | From any app, until recording starts: cancels the floating bar or the area selector |
| ⌘R | **Record Screen**, or **Stop Recording** while you record |
| ⇧⌘R | **Record Something Else…** |
| ⌘O | **Add Videos…** |
| Space | Preview the selected clips in Quick Look, the macOS preview window |
| ⌘N | **Clear Session** |
| ⌘, | Settings |

⌃⌥R opens the sheet instead of the bar when there's nothing to reuse. Once you're recording, Esc goes to the app you're
recording as usual.

The "From any app" shortcuts work whenever Screen Stitch is open, even when it's hidden. They can't launch Screen
Stitch, though. To open it with a key, use the Shortcuts app's **Open App** action with a keyboard shortcut.

To change ⌃⌥R or ⌃⌥S, open Settings, click the shortcut and press the new keys (Esc cancels). A shortcut needs a key
plus at least two of ⌃ ⌥ ⇧ ⌘. A function key (F1–F20) works with or without ⌃ ⌥ ⇧ ⌘. **Use Defaults** restores both.
Turn off **Use from any app** to disable both shortcuts and the Esc cancel.

## Adding clips you already have

- Click **Add Videos…** (⌘O) or drop video files on the window or the Dock icon. Anything that isn't a readable video
  is skipped, with a warning.
- Click **Watch for Recordings** to pick up recordings from the macOS Screenshot toolbar (⇧⌘5). Each one is added as
  soon as it finishes. Screen Stitch watches the folder the toolbar saves to (its Options › Save to setting, which is
  the Desktop unless you've changed it) and ignores videos already there. While it watches, the bottom bar has
  **Change…** to watch a different folder and **Stop Watching**.

## Arranging clips

- New clips are placed by when they were recorded (see [Order](how-it-works.md#order)). Drag rows to reorder them, and
  the video follows the list from top to bottom. **Sort by Date** puts the clips back in recording order.
- Click a thumbnail to play that clip in Quick Look. Or select rows and press Space, as in the Finder: ⌘-click or
  ⇧-click to select several, and ↑ and ↓ to move. While Quick Look is open, ↑ and ↓ switch clips.
- Click a row's ⓧ to take it out of the list. That doesn't delete its file. Right-click a row for **Show in Finder**.

## Title cards

Title cards put text between clips. Add them from **Title Cards** in the list header, above the clips:

- **Before & After** appears when the list has exactly two clips. It adds a "Before…" card above the first clip and an
  "After…" card between the two clips, to show a change. Choose it again to remove them.
- **Add Title Card** adds a card after the selected row, or at the end.

A card is a row you can drag like a clip. Type its text, set how many seconds it shows (0.25 to 10) and choose **Dark**
or **Light**. In the video, it fills the frame with large, centered text and has no sound.

Title cards aren't files, so they don't survive **Clear Session**.

## Combining

Choose a **Resolution** and **Quality** in the bottom bar. The defaults suit most videos, and
[How it works](how-it-works.md#resolution-and-quality) explains the options. Then click **Combine & Compress…** and
choose where to save the video. With only one clip, the button says **Compress…**. While it works, **Cancel** stops it
and deletes the unfinished file.

When it's done, the bottom bar shows the saved video and its size compared with the clips, with **Show in Finder** and
**Open**.

> [!TIP]
> With two or more clips that all have the same size and format, an arrow next to **Combine & Compress…** offers
> **Combine Without Compressing…**. It joins the clips as they are, so it's much faster and loses no quality, but the
> file is about as big as the clips put together. Recordings of the same window or area usually qualify, as long as the
> microphone was on for all of them or off for all of them. The option disappears while the list has title cards.

## Starting over

Click **Clear Session** (⌘N) to empty the list and begin a new session. It's in the list header, and in the bottom bar
once you've saved the video. Screen Stitch asks what to do with the files first:

| Choice | What happens |
| :--- | :--- |
| **Keep Files** (the default) | Every file stays where it is. |
| **Move Clips to Trash** | Every clip in the list goes to the Trash, including ones you added from elsewhere. The dialog says how many of those there are. |
| **Move Everything to Trash** | The clips go to the Trash, along with any video you saved in this session that's still where you saved it. It's only offered when there is one. |
| **Cancel** | Nothing changes. |

Nothing else is touched, and you can put anything back from the Trash.

## Troubleshooting

### "FFmpeg isn't installed"

Install FFmpeg (`brew install ffmpeg`), then click **Quit & Reopen**. Screen Stitch looks for `ffmpeg` and `ffprobe` in
`/opt/homebrew/bin`, `/usr/local/bin`, `/opt/local/bin` and `/usr/bin`, in that order, and uses the first folder that
has both.

### The sheet asks for Screen Recording permission

The sheet needs the permission to list windows and displays. Click **Open System Settings**, turn Screen Stitch on, then
click **Quit & Reopen**.

Or click **Use macOS Picker…**, which doesn't need the permission. Recording starts as soon as you pick a window, app or
display there, without the clapperboard, and you can't record an area this way.

### Permissions are gone after an update

macOS forgets Screen Stitch's permissions after each update unless you set up the
[signing certificate](development.md#signing). To fix it:

1. Open System Settings › Privacy & Security › Screen & System Audio Recording.
2. Select the old Screen Stitch entry and click **−**.
3. Open Screen Stitch and try to record. Grant the permission again when it asks.

If you'd also turned on Accessibility (Device Control and Data Access in macOS 27), remove that entry the same way. To
turn it back on, see [Another window covers the one you picked](#another-window-covers-the-one-you-picked).

### The window you picked isn't on screen

The floating bar asks you to click the app's icon in the Dock, or the window itself there if it's minimized. **Start**
won't record until the window is back.

### Another window covers the one you picked

The floating bar says so and offers **Bring to Front**, so you can see the window while you record. A covered window
still records normally.

To bring that exact window forward, Screen Stitch needs Accessibility permission. Until you turn it on, **Bring to
Front** opens the right page in System Settings: Privacy & Security › Accessibility, or Device Control and Data Access
in macOS 27. Turn Screen Stitch on there. You don't need to relaunch. Without the permission, Screen Stitch can only
bring the whole app forward, so a different window of the same app may end up in front. Either way, it can't reach a
window on another desktop.

### A shortcut doesn't work

If macOS or another app already uses the keys, Settings says so in red and the shortcut won't work. macOS's own
shortcuts always win, so to use one of them (such as ⇧⌘5), turn it off in System Settings first. **Open Keyboard
Settings…** in Screen Stitch's Settings takes you there. Settings can't see shortcuts that only work inside another
app's menus, so it can't warn you about those.
