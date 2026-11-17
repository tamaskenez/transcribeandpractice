# Prototype application

The prototype application is a throwaway implementation to experiment with the basic functionality.

## Overview of features

- Load audio file
- Display navigator window (waveform)
- Display main, analyzer window (switchable between waveform and spectrogram)
- Show both horizontal and vertical orientations (time goes to the right or downwards)
- Selection
- Navigation, pan, zoom
- Various playback options:
  - start at playhead, selection begin, previous start, stop
  - looping playback
- Manually place beat markers, edit them
- snap to beat navigation
- Display note grid on spectrogram
- Edit notes by clicking into the note grid, snap to desired beat division (1/4, 1/16, ...)
- Play note corresponding to mouse location in the grid

## Detailed specification

### Technology

- Swift 6 and SwiftUI for the app shell: window, menus, and later the toolbar and panels.
- AppKit `NSView`s embedded in SwiftUI for custom high-performance views (waveform, spectrogram,
  note grid; from milestone 2 on).
- AVFoundation for decoding and playback; Accelerate (vDSP) for FFT (from the spectrogram on).
- Project setup (proposed): a Swift Package built from the command line, plus a script that wraps
  the executable into a `.app` bundle. This avoids keeping an Xcode project file in sync.
- Minimum macOS version: 26.

Rationale: the end product is planned as a C++ core with a thin native UI per platform (see
high_level_features.md), so the macOS UI layer will most likely be Swift/SwiftUI anyway, and Swift
can call C++ directly. The prototype needs no heavy DSP, so everything stays in Swift.

### Application window

- Single-window app. Opening a file replaces the currently loaded one.
- The window title shows the loaded file's name; with no file loaded it shows the app name.
- With no file loaded, the window shows a hint: "Open an audio file (⌘O)" (from milestone 2 on, in
  the main pane).

### Window layout (from milestone 2)

The window is split into panes:

- Toolbar: the native macOS window toolbar (merged into the title bar). It is dedicated to
  view- and selection-related tools and indicators. Milestone 2: the time-orientation toggle
  (horizontal / vertical). From milestone 3 also: Zoom Out Full and Zoom to Selection buttons, and
  the selection indicator (see Navigation and selection).
- Middle section: a navigator pane and a main (analysis) pane, separated by a draggable divider.
  - Horizontal time (time runs to the right): navigator on top, main pane below.
  - Vertical time (time runs downwards): navigator on the left, main pane on the right.
  - The navigator starts at about 20% of the middle section; the main pane gets the rest.
- Transport pane: a strip at the bottom of the window. Playback controls come in a later
  milestone. Until then it shows a one-line file summary (see File information display).

Orientation:

- Switched by the toolbar toggle, or View → Horizontal Time (⌘1) / Vertical Time (⌘2).
- The choice is remembered across launches. The default is horizontal.

### Waveform display (from milestone 2)

- Both the navigator and the main pane show a mono waveform: the average of all channels.
  Milestone 2: both show the whole file. From milestone 3 on, both show the same visible time
  range (see Navigation and selection).
- Drawing: for each pixel column (each pixel row in vertical mode), take the fractional sample
  position of that column and linearly interpolate the mono signal there. The resulting points are
  joined into a polyline. This aliases badly when zoomed out; that is accepted for now.
- The amplitude axis is linear: full scale (±1.0) fills the pane's height (width in vertical mode),
  with 0 in the middle. In vertical mode positive values go to the right.
- With no file loaded the panes are empty, and the main pane shows the hint.

### Navigation and selection (from milestone 3)

Visible range:

- The navigator and the main pane always show the same visible time range. Zooming or panning in
  either pane changes both.
- The visible range can't be shorter than 100 ms (maximum zoom). It may extend beyond the file
  by a margin of half of that (50 ms) at both ends: it always lies within −50 ms … file end +
  50 ms, and fully zoomed out it is exactly that range. No waveform is drawn in the margins.
  (Changed in the milestone 3 review; originally 1 ms and limited to the file.)
- Resizing the window, dragging the divider or switching orientation keeps the visible time range
  (only the scale changes).
- Opening a file shows the whole file and clears the selection.

Zoom (time axis only; the amplitude scale doesn't change):

- Trackpad pinch: zooms around the pointer (the time under the pointer stays under the pointer).
- ⌘ + scroll (wheel or two-finger scroll along either axis): zooms around the pointer. Scrolling
  up / away zooms in.
- Toolbar Zoom Out Full: shows the whole file plus the margins. Disabled when that is already
  shown.
- Toolbar Zoom to Selection: makes the visible range equal to the selection (widened to 100 ms
  around its center if shorter, then shifted inside the limits). Disabled when there is no
  selection.

Pan:

- Scrolling along the time axis (two-finger trackpad scroll, scroll wheel) pans, following the
  system's scroll direction setting. In horizontal mode both scroll axes pan time (so a plain
  mouse wheel works); in vertical mode only the vertical scroll axis does.
- Option + drag and middle-button drag grab the waveform: the time under the pointer follows the
  pointer.
- The navigator has a scrollbar along its time axis: at the navigator's bottom edge in horizontal
  mode, at its right edge (next to the main pane) in vertical mode. The knob shows the visible
  range's position and size within the whole file; dragging it, or clicking the track, pans. The
  scrollbar is always visible (legacy style, not the auto-hiding overlay style).
- Panning stops 50 ms beyond the start and end of the file. The scrollbar spans the same range.

Selection:

- One selection at a time: a time range in the file.
- Plain drag along the time axis in either pane selects the range between the press and the
  release positions (either direction), limited to the visible range (no autoscroll).
- Shift-click / shift-drag extends the existing selection: the end nearer to the click moves to
  the pointer. With no selection, shift-drag acts as a plain drag.
- A click without a drag, or Escape, clears the selection.
- The selection is drawn as a translucent accent-colored band across both panes.
- Toolbar selection indicator (read-only): `start – end (length)` in the duration format of the
  transport summary (e.g. `0:01.250 – 0:02.000 (0:00.750)`), or `–` with no selection.

### Loading audio files

- File → Open… (⌘O) shows the standard open dialog, limited to audio files. This is the only way to
  open a file (no drag and drop, Open Recent or Finder/Dock opening).
- Supported formats: whatever AVFoundation can decode (WAV, AIFF, CAF, MP3, AAC/M4A, ALAC, FLAC).
- The whole file is decoded into memory: all channels, at the file's own sample rate, as 32-bit
  float.
- Loading is blocking: the UI is unresponsive while the file is decoded.
- If a file can't be opened or decoded, an alert shows the reason, and the previously loaded file
  (if any) stays loaded.

### File information display

After loading, the window shows (milestone 1):

- file name
- duration
- sample rate
- channel count
- length in sample frames
- peak and RMS level per channel, in dBFS

From milestone 2 on, the waveform panes take the window's space, and the transport pane shows a
one-line summary instead: file name, duration, sample rate, channel count. The full details
(including frames and levels) remain in the state dump.

### Verification hooks

For headless verification the app accepts launch arguments (`--open=<file>`, `--dump-state=<file>`,
`--snapshot=<file>`, `--quit`) that open one or more files in order
(through the same code path as File → Open, minus the dialog), write the app's state to a JSON file
(loaded file info, window title, error alert text, main menu structure), save a PNG snapshot of the
window content, and quit.

From milestone 2 on, also: `--orientation=horizontal|vertical` (sets the orientation through the
same code path as the toggle, so it is also remembered); the dump adds the orientation, the window
number, the frames of all panes, the divider position, and the polyline points of each waveform
pane. From milestone 3 on, also: `--view=<start>,<end>` and `--select=<start>,<end>` (seconds;
set the visible range / selection through the same code paths as the gestures, including the
limits); `--commands=<file>` keeps the app running and executes commands appended to that file
(`dump <path>`, `snapshot <path>`, `quit`, and `view`, `select`, `orientation`, `open`, `resize`,
`activate`), acknowledging each in `<file>.ack`, so a test driver can post synthetic input events
between dumps; the dump adds the visible range, the selection, the toolbar selection text and
button states, and the scrollbar's frame and knob position/proportion. From milestone 2 on, `--snapshot` captures the real window, including the toolbar, by running
`screencapture -l <window number>` (needs Screen Recording permission for the terminal that
launches the app). These are a development aid, not a user feature.

To build and run the prototype: `prototype/build.sh`, then open `prototype/build/TranscribeAndPractice.app`.
Alternatively, the root `CMakeLists.txt` builds the same app bundle (e.g. from CLion).

## Decisions

- Code lives in `prototype/`: a Swift package plus `build.sh`, which creates
  `build/TranscribeAndPractice.app`. Verification scripts are in `prototype/verify/`.
- CMake build (for CLion): the root `CMakeLists.txt` includes `prototype/CMakeLists.txt`, which
  globs `Sources/**/*.swift` into a `MACOSX_BUNDLE` target. `Info.plist` is shared by both builds.
- Numbers in the info display use the system locale (e.g. "44.100 Hz" with a Hungarian locale).
- Levels of a fully silent channel are shown as "-∞ dBFS".
- A WAV file that is cut short loads the audio it contains (as audio players do); AVFoundation
  doesn't report it as an error. Files that can't be decoded at all show the error alert.
- Error alerts for unreadable files say "It is not a supported audio file, or it is damaged" with
  the Core Audio error code, instead of the raw system message.
- (Milestone 1; replaced in milestone 2 by `screencapture`, see below.) Snapshots are rendered from
  the window's SwiftUI view tree with `ImageRenderer`. Capturing the
  real window from inside the process comes out blank on macOS 26, and capturing it from outside
  would need Screen Recording permission. Consequence: window chrome isn't in the snapshots, and
  AppKit views embedded in SwiftUI (from milestone 2 on) may need their own rendering path.
- Hook options use the `--option=value` form; with a separate path argument, AppKit treated the
  launch as opening a file and SwiftUI didn't create the main window.
- Waveform columns are screen points, not physical (Retina) pixels: a pane with a time-axis length
  of L points gets L+1 polyline points at integer positions 0…L.
- The navigator/main divider is a custom SwiftUI drag handle rather than `VSplitView`/`HSplitView`,
  which can't set the initial 20% position. The position is clamped to 5–95% and isn't
  remembered across launches (only the orientation is). Its drag area overlaps the panes by 3
  points, so the waveform views don't take mouse events yet.
- Colors: navigator on the under-page background, main pane on the text background, waveform in
  the accent color, with a faint zero line.
- Default window size 1000×700 points; minimum content size 600×400.
- The mono mix is computed once, when the file is loaded.
- The state dump keeps the `displayedRows` key (the milestone 1 info rows) although the full info
  grid is no longer on screen.
- (Milestone 3) Time model: the visible range and the selection are in seconds. Waveform point i
  of a pane with time-axis length L is at time start + i·(end − start)/L, read at sample position
  time·sampleRate; positions outside 0…frames−1 (in the margins) get no point. (Milestone 2
  mapped the whole file to sample positions 0…frames−1; `verify_m2.py` now compares against the
  milestone 3 model with the dumped visible range.)
- The selection stays within the file; it can't extend into the margins.
- Zoom rates: ⌘ + scroll zooms by e^(0.01·d) for a scroll of d points; a positive vertical delta
  (wheel turned up / away, or two fingers moved down with natural scrolling) zooms in. A pinch
  zooms by 1 + magnification per event. Line-based mouse wheels count as 10 points per line, for
  panning too.
- A press that moves less than 2 points before release counts as a click (clears the selection).
- The waveform panes accept the first click on an inactive window (it acts immediately instead of
  only activating the window).
- Clicking the scrollbar track pages by one visible length, or jumps there, per the system's
  "Click in the scroll bar to" setting.
- Toolbar icons: Zoom Out Full `arrow.left.and.right.square`, Zoom to Selection
  `arrow.right.and.line.vertical.and.arrow.left` (SF Symbols).
- Escape is handled by an application-wide key monitor (no view has keyboard focus yet); it does
  nothing while an alert is shown.
- The divider's drag area still overlaps the panes by 3 points and wins there, although the
  waveform panes now take mouse events.
- Verification posts synthetic events with a small Swift tool (`verify/inputdriver.swift`, built
  by the script). It brings the app to the front through Accessibility first: events go to
  whatever window is under the pointer, and the scroller and divider ignore the first click on an
  inactive window. Pinch is synthesized with undocumented gesture event fields (type 29, zoom
  subtype, magnification), which macOS 26 accepts.
