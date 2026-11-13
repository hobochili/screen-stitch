# User guide

[Recording](#recording) · [Shortcuts](#shortcuts) · [Adding clips](#adding-clips-you-already-have) ·
[Arranging clips](#arranging-clips) · [Removing clips](#removing-clips) · [Title cards](#title-cards) ·
[Redacting text](#redacting-text) · [Combining](#combining) · [Starting over](#starting-over) ·
[Troubleshooting](#troubleshooting)

A **session** is the clips in the list plus the video you save from them. Record or add clips, put them in order, then
combine them. When you're done, click **Clear Session** to start the next one. Screen Stitch keeps your session between
launches (see [Starting over](#starting-over)).

Before you have any clips, the window shows a big red **Record Screen** button, with **Add Videos…** below it. After
that, it shows the list of clips. **Title Cards**, **Sort by Date** and **Clear Session** are in the header above the
list, and **Record Another** is just below it. The bottom bar, along the bottom of the window, is where you choose
**Resolution** and **Quality** and combine the clips. The toolbar at the top has **Record Microphone**,
**Watch for Recordings** and **Add Videos…**. Until you have a clip, **Watch for Recordings** is only in the File menu.

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
- **Change…** picks something else, and **Cancel** backs out. Esc doesn't: it goes to the app you're about to record.
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
| Esc | From any app, while you drag out an area: cancels the area selector |
| ⌘R | **Record Screen**, or **Stop Recording** while you record |
| ⇧⌘R | **Record Something Else…** |
| ⌘O | **Add Videos…** |
| Space | Preview the selected clips in Quick Look, the macOS preview window |
| ⌘N | **Clear Session** |
| ⌘, | Settings |

⌃⌥R opens the sheet instead of the bar when there's nothing to reuse. Once the floating bar is up, Esc goes to the app
you're recording as usual, so use the bar's **Cancel** to back out.

The "From any app" shortcuts work whenever Screen Stitch is open, even when it's hidden. They can't launch Screen
Stitch, though. To open it with a key, use the Shortcuts app's **Open App** action with a keyboard shortcut.

To change ⌃⌥R or ⌃⌥S, open Settings, click the shortcut and press the new keys (Esc cancels). A shortcut needs a key
plus at least two of ⌃ ⌥ ⇧ ⌘. A function key (F1–F20) works with or without ⌃ ⌥ ⇧ ⌘. **Use Defaults** restores both.
Turn off **Use from any app** to disable both shortcuts and the Esc that cancels the area selector.

## Adding clips you already have

- Click **Add Videos…** (⌘O) or drop video files on the window or the Dock icon. Anything that isn't a readable video
  is skipped, with a warning.
- Choose **Watch for Recordings** in the File menu, or click it in the toolbar once you have clips, to pick up
  recordings from the macOS Screenshot toolbar (⇧⌘5). The list can be empty. Each recording is added as soon as it
  finishes. Screen Stitch watches the folder the toolbar saves to (its Options › Save to setting, which is
  the Desktop unless you've changed it) and ignores videos already there. While it watches, the bottom bar says "Watching
  Desktop for new screen recordings" and has **Change…** to watch a different folder and **Stop Watching**.

## Arranging clips

- New clips are placed by when they were recorded (see [Order](how-it-works.md#order)). Drag rows to reorder them, and
  the video follows the list from top to bottom. **Sort by Date** puts the clips back in recording order.
- Click a thumbnail to play that clip in Quick Look. Or select rows and press Space, as in the Finder: ⌘-click or
  ⇧-click to select several, and ↑ and ↓ to move. While Quick Look is open, ↑ and ↓ switch clips.
- Right-click a row for **Preview**, **Show in Finder**, **Remove from List** and **Move to Trash**. If the row is one
  of several selected, **Show in Finder**, **Remove from List** and **Move to Trash** act on all of them. See
  [Removing clips](#removing-clips).

## Removing clips

Click a row's ⓧ, select rows and press Delete (⌫), or choose **Remove from List** in the row's menu. The clips leave the
list, but their files stay where they are. The bottom bar says what was removed and offers **Undo**. It also offers
**Move to Trash** when every removed clip was recorded in Screen Stitch this session.

**Move to Trash** (⌘⌫, the row's menu or the Edit menu) moves the clips' files to the Trash and takes their rows out of
the list. A clip recorded in this session goes straight away. A video you added from elsewhere asks first, since Screen
Stitch didn't make it. **Remove from List** is the default choice there.

A clip that a video still being saved uses can't be moved to the Trash. The bottom bar says so, and you can try again
once the video is done.

After that, **Put Back** in the bottom bar brings the files and their rows back. **Undo** and **Put Back** last until
the message fades (about 8 seconds) or the list changes. After that, use **Put Back** in the Finder's Trash.

## Title cards

Title cards put text between clips. Add them from **Title Cards** in the list header, above the clips:

- **Before & After** appears when the list has exactly two clips. It adds a "Before…" card above the first clip and an
  "After…" card between the two clips, to show a change. Choose it again to remove them.
- **Add Title Card** adds a card after the selected row, or at the end.

A card is a row you can drag like a clip. Type its text, set how many seconds it shows (0.25 to 10) and choose **Dark**
or **Light**. In the video, it fills the frame with large, centered text and has no sound.

Title cards aren't files, so they don't survive **Clear Session**.

## Redacting text

To redact something from the video, such as the last four digits of a card, click **Redact Text…** in the list header
(or choose it in the Edit menu). The start screen has a **Redact Text…** button too, so you can set it up before you
record. A small sheet opens. Type the text and click **Add** (or press Return). Pasting several
lines adds each one. Screen Stitch then looks through every clip for it, even as the page scrolls, and covers each place
it finds with a solid black box when you combine.

The boxes are permanent in the saved video. The covered pixels are replaced, not overlaid, so no one can remove a box to
see what was under it. Your original recordings are unchanged, so share only the saved video.

The sheet lists your text with a checkbox on each. A checked entry is redacted, and the status beside it says how often
it was found. Uncheck an entry to stop redacting it for now, or click ⓧ (**Stop Redacting**) to remove it. Screen Stitch
remembers the list between sessions, so **Redact Text…** is filled in while redaction is on and anything is checked. The bottom bar shows
what's redacted, for example "Redacting 9611 and 9820 · Looking through clip 2 of 5…", with **Change…** to reopen the
sheet.

The switch at the top right of the sheet turns redaction on or off. Off keeps your list but redacts nothing, and the
list turns grey. **Clear List…** at the bottom left removes every entry, after asking first.

The search runs by itself in the background, one clip at a time. It takes about half a minute per minute of video, so
about 10 minutes for 20 minutes, and short clips are quick. It keeps going while you record, but slower, so it doesn't get in
the recording's way. Screen Stitch remembers the places it found for each text, so it doesn't search a clip again for text it
has already searched. A new piece of text is searched for in every clip. A clip with text found shows a redaction icon in its row, and pointing at it says where, for example "Redacts
“9611” in 3 places". The boxes go into the video you save, not into the clip's file, so **Preview** still shows the
text.

When you click **Combine & Compress…**, Screen Stitch waits for any search still running, then redacts the text and
compresses. The bottom bar shows each step, such as "Looking through clip 2 of 5", then "Redacting text in “clip.mov”".

If a clip can't be searched, the list and the bottom bar say "Couldn't search “clip name”". Combining tries the search
again first. If it still fails, combining stops and the message says to remove the clip or uncheck the text.

Before you share the video, click **Check Redactions…** on the saved-video card (or the link on the **Saved** line). A
sheet plays the saved video and lists every place text was redacted. Click one, or use the arrows, to play it, and check
the box covers the text. If you can still read something, click **Still see something?**, then **Redact More Text…**,
add the text the way it appears, and combine again. That searches every clip for the new text, so it takes a while. If
you add text after saving, the card is replaced by the compact **Saved** line, which says "This video doesn't redact
“4242”. Combine again to redact it."

- Type the text as it appears on screen. Capital letters don't matter.
- Text needs at least 2 characters. Text under 4 characters matches only as a separate word, so "MN" covers "MN 55407"
  but not the letters inside "column". A letter next to a digit still counts as the edge of a word, so "MN55407" matches.
- Very small text, such as inside a scaled-down picture of another screen, can't be read reliably, so it may not be
  found.
- Text in rotated video can't be found yet. Screen Stitch says so instead of skipping the clip.
- Only what's on screen is redacted. Sound isn't changed.

## Combining

Choose a **Resolution** and **Quality** in the bottom bar. The defaults suit most videos, and
[How it works](how-it-works.md#resolution-and-quality) explains the options. Screen Stitch remembers both for next time.
Then click **Combine & Compress…** and choose where to save the video. With only one clip, the button says
**Compress…**.

Combining doesn't lock the window. Screen Stitch takes a snapshot of the list as it is now and saves the video in the
background, so you can clear the session, record and combine again while it works. Videos are saved one at a time, in
the order you started them. The bottom bar shows the one being saved, for example "Saving “Demo.mp4” · Compressing · 40%
· about 2 minutes left · 1 more waiting". **Cancel** stops it and deletes the unfinished file.

**Details** in the bottom bar opens the **Exports** list: every video since you opened Screen Stitch, with what it's
doing, a button to cancel it, and **Show in Finder** once it's saved. **Clear Finished** empties the finished ones.
**Show Log** opens the **Export Log**, which is also in the Window menu. It lists what searches and exports did, with
the time of each step, which helps when something is slow or fails. **Copy All** copies it and **Clear** empties it.

If you clear the session before a video is done, the video is still saved where you chose, but it isn't added to the new
session. A video being saved also keeps its clips in place. See [Removing clips](#removing-clips).

Before it starts, Screen Stitch checks that every clip's file is still there. If one was moved, renamed or deleted, the
bottom bar names it. Remove it from the list, or add it again from where it is now.

When it's done, the bottom bar shows the saved video and its size compared with the clips, with **Show in Finder**,
**Open** and **Share…**. **Share…** opens the macOS share menu. You can also drag the video's thumbnail into Mail,
Messages, a Finder window or any other app that takes files.

That card stays until you change the list. Then a smaller **Saved** line takes its place, with the video's name, size
and time, plus **Show in Finder**, **Open** and **Share…**. You can drag the name out like the thumbnail. If you've saved
several videos in this session, the line says "2 videos saved" instead. Click it to pick which video the line shows. A
saved video you delete or move in the Finder drops off the line.

> [!TIP]
> With two or more clips that all have the same size and format, an arrow next to **Combine & Compress…** offers
> **Combine Without Compressing…**. It joins the clips as they are, so it's much faster and loses no quality, but the
> file is about as big as the clips put together. Recordings of the same window or area usually qualify, as long as the
> microphone was on for all of them or off for all of them. The option disappears while the list has title cards. If you
> have [text to redact](#redacting-text), it waits until the search shows the text isn't in any clip.

## Starting over

Your session is saved as you go, so closing the window or quitting doesn't lose it. The next time you open Screen
Stitch, the clips, the text to redact, the title cards and the order are back. A clip that was moved or deleted, or can't
be read any more, is left out, and a warning names it. The **Saved** line for your videos comes back too, but the full
card doesn't.

Click **Clear Session** (⌘N) to empty the list and begin a new session. It's in the list header, and on the
saved-video card. Screen Stitch asks what to do with the files first:

| Choice | What happens |
| :--- | :--- |
| **Keep Files** (the default) | Every file stays where it is. |
| **Move Clips to Trash** | Every clip in the list goes to the Trash, including ones you added from elsewhere. The dialog says how many of those there are. |
| **Move Everything to Trash** | The clips go to the Trash, along with any video you saved in this session that's still where you saved it. It's only offered when there is one. |
| **Cancel** | Nothing changes. |

If the list is empty but you saved videos in this session, the choices are **Keep Files** and **Move Video to Trash**
(**Move Videos to Trash** for several). Nothing else is touched, and you can put anything back from the Trash.

Clips that a video still being saved uses stay where they are, whatever you choose, and the bottom bar says how many.
That video keeps saving after the session is cleared.

If you quit while a video is still being saved, Screen Stitch asks first. Quitting stops it and deletes the unfinished
file, so you'd combine again.

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
