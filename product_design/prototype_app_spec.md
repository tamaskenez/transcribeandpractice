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

- Toolbar: the native macOS window toolbar (merged into the title bar). For now it holds only the
  time-orientation toggle (horizontal / vertical).
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

- Both the navigator and the main pane show the whole file as a mono waveform: the average of all
  channels. (Zoom and pan come in milestone 3.)
- Drawing: for each pixel column (each pixel row in vertical mode), take the fractional sample
  position of that column and linearly interpolate the mono signal there. The resulting points are
  joined into a polyline. This aliases badly when zoomed out; that is accepted for now.
- The amplitude axis is linear: full scale (±1.0) fills the pane's height (width in vertical mode),
  with 0 in the middle. In vertical mode positive values go to the right.
- With no file loaded the panes are empty, and the main pane shows the hint.

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
pane. Snapshots of the real window, including the toolbar, are taken from outside the app with
`screencapture -l <window number>` (needs Screen Recording permission for the terminal). These are a development aid, not a user feature.

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
- Snapshots are rendered from the window's SwiftUI view tree with `ImageRenderer`. Capturing the
  real window from inside the process comes out blank on macOS 26, and capturing it from outside
  would need Screen Recording permission. Consequence: window chrome isn't in the snapshots, and
  AppKit views embedded in SwiftUI (from milestone 2 on) may need their own rendering path.
- Hook options use the `--option=value` form; with a separate path argument, AppKit treated the
  launch as opening a file and SwiftUI didn't create the main window.
