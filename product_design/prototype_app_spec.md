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
  50 ms, and fully zoomed out it is exactly that range. No waveform is drawn in the margins: only
  the faint zero axis line, which is distinct from the accent-colored line of zero-valued samples.
  (Changed in the milestone 3 review; originally 1 ms and limited to the file.)
- Resizing the window, dragging the divider or switching orientation keeps the visible time range
  (only the scale changes).
- Opening a file shows the whole file and clears the selection.

Zoom:

- Trackpad pinch: zooms time around the pointer (the time under the pointer stays under the
  pointer). A pinch has no direction, so it always zooms time.
- ⌘ + scroll along the time axis (horizontal scroll in horizontal mode, vertical scroll in
  vertical mode): zooms time around the pointer.
- ⌘ + scroll across the time axis (vertical scroll in horizontal mode, e.g. a plain mouse wheel;
  horizontal scroll in vertical mode): amplitude zoom. A positive scroll delta zooms in, in both
  directions. (Changed in the milestone 3 review; originally any ⌘ + scroll zoomed time.)
- (Milestone 9) A ⌘ + scroll gesture zooms only one axis: the one with the larger delta in the
  gesture's first event (see "Spectrum and piano keys").
- Amplitude zoom: a multiplier applied to the sample values of both waveform panes, between
  0 dB (×1, full scale fills the pane) and +60 dB (×1000). The zero line stays in the middle; the
  waveform is clipped at the pane edges. It is reset to 0 dB by Zoom Out Full and by opening a
  file.
- Toolbar Zoom Out Full: shows the whole file plus the margins, at 0 dB amplitude zoom. Disabled
  when that is already the case.
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
- Dragging a selection edge (within 4 points of it along the time axis, in either pane) moves
  that edge; it keeps its offset from the pointer, stays within the visible range, and dragging it
  past the other edge flips the selection. The cursor over an edge is the left-right resize arrow
  (horizontal mode) or the up-down one (vertical mode).
- Dragging inside the selection moves the whole selection (the same offset added to start and
  end); it stops at the file's start and end. The cursor inside the selection is an open hand,
  a closed hand while moving.
- With Option or Shift held, the cursor stays the arrow and the press acts as described above
  (pan, extend).
- A click without a drag, or Escape, clears the selection (also when the click is on an edge or
  inside the selection).
- The selection is drawn as a translucent accent-colored band across both panes.
- Toolbar selection indicator (read-only): `start – end (length)` in the duration format of the
  transport summary (e.g. `0:01.250 – 0:02.000 (0:00.750)`), or `–` with no selection.

### Playback (from milestone 4)

State:

- Playhead: a time position in the file (0 … duration). Shown as a line across both waveform
  panes and as a mark on the navigator scrollbar's track.
- Rewind point: the selection start, or, with no selection, where the user last clicked to clear
  the selection or set the playhead (file start after opening a file).
- Last playback start: where the most recent playback started (file start after opening). Every
  direct change of the playhead by the user also puts it at the playhead: a click that clears the
  selection, Escape, a new selection, dragging the playhead line. Shown as a line in both
  waveform panes and a mark on the scrollbar, in a desaturated playhead red, drawn before the
  playhead (the playhead covers it where they coincide). Can also be set with
  set-last-playback-started and by dragging its line.
- Loop enabled flag; follow-playhead flag. Both are remembered across launches; defaults off.
- Opening a file stops playback and puts the playhead, rewind point and last start at 0.

Actions:

- Play-or-stop (Space, transport button): if playing, stop (the playhead stays at the audible
  position); otherwise start playing at the playhead.
- Rewind-and-play (Left Arrow, transport button): set the playhead to the rewind point and play
  (restarts if already playing).
- Play-again (Right Arrow, transport button): play from the last playback start (restarts if
  already playing).
- Set-last-playback-started (Down Arrow): the last playback start becomes the playhead position
  (also during playback; play-again then starts there).
- Loop (transport toggle button).
- Mouse: a click without a drag (which clears the selection) stops playback and sets the playhead
  and the rewind point to the clicked time (limited to the file). Starting a new selection by
  dragging stops playback and keeps the playhead at the selection start. Escape (clears the
  selection) stops playback and puts the playhead at the former selection start. Extending,
  dragging an edge or moving the selection does not stop playback or move the playhead; a
  running playback uses the changed selection from then on.
- Dragging lines: the playhead line (only when not playing), the last-playback-start line and the
  selection edges can be hovered (resize arrows, within 4 points) and dragged like the selection
  edges. A press grabs the nearest line and every other line at the same time (within one
  sample; at most one selection edge), and they move together: e.g. after a new selection the
  selection start, playhead and last start. The dragged position is limited to the visible range
  and the file. Dragging the playhead also sets the last start and (for when there is no
  selection) the rewind point. Dragging the last start alone doesn't affect playback. A click
  without a drag on a line clears the selection as elsewhere.

Where playback ends:

- The selection end only matters when the playback crosses it: the play position reaches it from
  before. If the selection end is moved before the play position during playback, it is not
  crossed, and playback goes on to the file end. While the user is dragging a selection edge,
  moving the selection or shift-extending it, the end is ignored (a drag sweeping the end back
  past the playhead would otherwise "cross" it); the end at release counts.
- Selection, loop off: playback stops at the selection end, with the playhead at the selection
  end (so play-or-stop continues from there; rewind-and-play goes back to the selection start),
  only if the playback started at the selection start (within one sample).
  This is decided when playback starts and holds even if the selection is changed or moved
  afterwards. Otherwise (e.g. stop and continue within the selection) playback continues through
  the selection end.
- Selection, loop on: if the playback started inside the selection (start ≤ playhead < end), at
  the selection end it continues at the selection start, without a gap (sample-accurate).
  Playback that started outside the selection ignores it.
- Otherwise playback stops at the file end and the playhead rewinds to the file start.

Output:

- The file's own channels: stereo as stereo, mono on both channels, more than two channels: the
  first two. No resampling by the app (the system converts to the device rate if needed).
- Audio engine: AVAudioEngine with an AVAudioSourceNode whose render callback copies from the
  decoded buffer. The output device's I/O buffer size is set to the smallest multiple of the
  display refresh period that is ≥ 30 ms (e.g. 33.3 ms at 60 or 120 Hz), limited to 30–50 ms and
  to the device's allowed range; without a known refresh rate, 40 ms.
- The playhead is updated once per render callback: the start of the buffer being rendered minus
  the output latency (device latency + safety offset + I/O buffer, as reported by Core Audio), so
  it shows what is audible. It never goes before the playback start.

Transport pane (left to right): rewind-and-play, play-or-stop (play / stop icon), play-again,
loop toggle, playhead position (`m:ss.mmm`), then the file summary.

Follow playhead (toolbar toggle button):

- Off: the view never moves by itself.
- On, while playing: the view eases toward having the playhead in the center (time constant
  about 0.5 s, updated at the display refresh rate; the view moves along with the playhead, so
  only the offset is eased). If the visible range is shorter than 5 s, it also eases out to 5 s
  (or the whole file plus margins, if shorter). The usual view limits apply.
- Follow starts (engages) only when the playhead reaches the view center; while the playhead is
  in the view before the center, the view stays. A playhead outside the view engages it at once.
- Follow doesn't engage while the expected end of the playback is in the view: the point where
  it will stop or loop back (the selection end if it applies, otherwise the file end) and, when
  looping, also the loop start (the selection start).
- Once engaged, follow stays engaged until the playhead jumps back (loop) or playback restarts;
  then the rules above decide again.
- A manual view change during playback (scroll, pinch, ⌘ + scroll, Option/middle drag,
  scrollbar, zoom buttons) turns follow off. When stopped, manual view changes don't affect the
  flag.

### Time markers (from milestone 5)

Layout:

- The navigator has a time-marker strip along its time axis, on the side away from the
  scrollbar: across the top in horizontal mode (about 18 points tall), down the left side in
  vertical mode (wide enough for the longest label of the file plus padding). The navigator
  waveform takes the rest of the pane; the scrollbar stays where it is. The main pane has no
  strip.
- The strip shows labelled (major) ticks and shorter unlabelled (minor) ticks between them. Each
  label sits right of its tick in horizontal mode and below it in vertical mode, in normal
  (unrotated) text.
- The playhead line and the last-playback-start line extend through the strip; the selection band
  does not (review change).
- Ticks are only drawn within the file (0 … duration). With no file loaded the strip is empty.
- The strip follows every change of the visible range (zoom, pan, follow, resize, divider,
  orientation).

Ticks and labels:

- The major step is the smallest value from 0.001, 0.002, 0.005, 0.01, 0.02, 0.05, 0.1, 0.2, 0.5,
  1, 2, 5, 10, 15, 30 s, 1, 2, 5, 10, 15, 30, 60 min… at which neighbouring labels don't overlap
  (at least 30 points of space between them; review change, was 8). Major ticks are at the multiples of the step.
- Minor ticks divide each step evenly: 5 parts for steps starting with 1 or 5 (1 s, 5 s, 0.1 s…),
  4 parts for steps starting with 2, 3 parts for 15 s / 15 min, 6 parts for 30 s / 30 min. Minor
  ticks are drawn only if they are at least 4 points apart.
- Labels are `m:ss`, with as many decimals as the step needs (no trailing zeros forced beyond
  that): 5 s step → `0:05`, `0:10`; 0.5 s → `0:01.5`; 0.05 s → `0:01.25`; 0.001 s → `0:01.234`.
  Minutes are not wrapped into hours (`75:00`).

Mouse in the strip (does not change the selection):

- Stopped: a press puts the playhead at the pointer (limited to the visible range and the file),
  and dragging moves it with the pointer (silently). As with any direct playhead change, the last
  start and the clear point (the rewind point when there is no selection) go to the playhead.
  Playback does not start.
- Playing: a press jumps playback to the pointer and it keeps playing, as if play-again were
  invoked from there: the last start goes there, and the stop/loop rules are decided anew from
  that start (see Where playback ends); the follow latch is reset. Moving the pointer afterwards
  does nothing until release.
- The last-playback-start line can be grabbed in the strip (within 4 points, resize arrows on
  hover) and dragged like in the waveform panes, stopped or playing. Grabbing it when it coincides
  with the playhead (stopped) moves both, as a playhead drag. Selection edges can't be grabbed in
  the strip, and dragging there never selects. Shift and plain clicks behave the same.
- Option/middle drag, scrolling, ⌘ + scroll and pinch work in the strip as in the navigator.

### Beat markers (from milestone 6)

Data:

- Each loaded file has a list of beats, sorted by position, at most one per sample. A beat has:
  - `sample`: its position, a sample frame index of the file (0 ≤ sample < frame count).
  - `source`: `placed` (put there by the user; the app never changes it) or `computed`
    (extrapolated by the app from the placed beats; recomputed whenever the placed beats change,
    from milestone 7).
  - `timeSignature` (optional): e.g. `4/4`, `3/4`, `6/8`. A beat with one introduces that time
    signature; a beat without one inherits the previous. Stored only in milestone 6 (used from
    milestone 7).
  - `firstBeat`: `no`, `placed` or `computed`. Anything but `no` makes the beat a downbeat (the
    first beat of a bar): set by the user (`placed`) or by the app (`computed`, from milestone 7).
- Milestone 6 has no editing. The beats come from a sidecar file next to the audio file: the full
  audio file name plus `.beats.json` (`song.mp3` → `song.mp3.beats.json`), read when the audio
  file is opened. Format: a JSON array of objects
  `{"sample": 44100, "source": "placed", "timeSignature": "3/4", "firstBeat": "no"}`
  (`timeSignature` may be left out; other keys are ignored). The entries may come in any order;
  the app sorts them.
- No sidecar file: the file has no beats. An invalid sidecar file (not JSON, not an array of
  objects, a missing or unknown field value, a malformed time signature, a sample outside the
  file, two beats at the same sample): an alert names the sidecar file and the problem; the audio
  file opens normally, with no beats. An empty array is valid (no beats).
- Opening another audio file replaces the beats with that file's.

Display (the navigator's marker strip):

- Beats mode shows the beats instead of the time ticks; time mode shows the time ticks of
  milestone 5. Toolbar toggle "Show Beats" and View → Show Beats (⌘B, with a checkmark) switch
  between them. Beats mode is the default; the choice is remembered across launches. While the
  loaded file has no beats (or no file is loaded), the button and the menu item are disabled and
  the strip shows time, but the stored choice is kept.
- Each beat is drawn at its sample's time, in the same mapping as the time ticks:
  - Downbeat with a bar number: a big tick (the full strip thickness, like a major time tick)
    with the bar number as its label (placed like the time labels: right of the tick in
    horizontal mode, below it in vertical mode). A big tick of a beat with `firstBeat: computed`
    is dotted.
  - Other beats: a small tick (as long as a minor time tick) for a placed beat, a dot instead for
    a computed beat.
- Bar numbers count the downbeats from the start of the file: the first downbeat is bar 1. Beats
  before the first downbeat (a pickup) have small ticks or dots and no number.
- Crowding (zoomed out):
  - Bar numbers are shown on every k-th bar (bars 1, 1 + k, 1 + 2k …), with k the smallest of 1,
    2, 4, 8 … at which neighbouring numbered bars in the visible range keep at least 30 points
    between their labels (as for the time labels). The other downbeats are drawn as other beats
    (small tick or dot).
  - Small ticks and dots are drawn for all beats if neighbouring beats in the visible range are at
    least 4 points apart; otherwise only for the un-numbered downbeats if those are at least
    4 points apart; otherwise none.
- In vertical mode the strip is wide enough for the widest time label and the widest bar number
  of the file.
- The mouse in the strip behaves the same in both modes (see Time markers).

Pointer line:

- A thin grey line across the strip at the time under the mouse pointer, in both modes, while
  the pointer is over the navigator waveform, the strip or the main waveform pane (all three
  share the visible range). It is hidden when the pointer is anywhere else (scrollbar, divider, toolbar,
  transport pane, outside the window).
- It follows the pointer's time also when the view moves under a still pointer (pan, zoom,
  follow), and during drags.

### Placing and editing beats (from milestone 7)

Constants (not on the UI yet): `beat_note` = 1/4 (a rational number: the note value BPM refers
to), `min_reasonable_bpm` = 30, `max_reasonable_bpm` = 240. The minimum distance between placed
beats is 60 / `max_reasonable_bpm` = 0.25 s.

Placing (keyboard; plain B and Shift+B, no Command / Option / Control):

- B places a placed beat (`firstBeat: no`) at the sample under the mouse pointer, while the
  pointer is over the navigator waveform, the time-marker strip or the main pane (the pointer
  line's time, rounded to the nearest sample). During playback it uses the playhead instead of
  the pointer (wherever the pointer is).
- Shift+B does the same with `firstBeat: placed` (a placed downbeat).
- Refused, with a system beep and no change: no file loaded; the pointer not over those panes
  (when stopped); the time outside the file; another placed beat closer than 0.25 s.
- A new beat at the position of a computed beat replaces it.
- Works in both strip modes (the beats are placed even while the strip shows time).

Time signature dialog:

- When a new beat becomes the first beat of the file (the first beat at all, or placed before
  all others), a modal dialog asks for its time signature: a numerator text field (digits only,
  prefilled with 4, at least 1) and a denominator popup (1, 2, 4, 8, 16, 32, 64, 128; 4
  preselected), with the buttons "Don't set" and "OK". OK sets the new beat's time signature;
  "Don't set" leaves it without one. The beat is placed either way.
- During playback the beat is placed at once and the dialog appears when playback stops (once,
  for the beat that is then first, if it is still first and still has no signature).
- Time signatures with a denominator up to 128 are valid (the milestone 6 sidecar validation is
  extended from 64).

Editing in the strip (beats mode, stopped only):

- Hovering a drawn beat mark in the strip (within 4 points along the time axis) shows the open
  hand cursor (closed while dragging). This takes precedence over the last-start line's grab and
  the plain strip press there.
- Dragging moves the beat: it stays at least 0.25 s from the neighbouring placed beats (it can't
  pass them), within the file and the visible range. The computed beats are recomputed live
  while dragging. A computed beat that is dragged becomes a placed beat. `firstBeat` and
  `timeSignature` are not changed by dragging (the order of placed beats can't change, so the
  signature stays where it was).
- A click without a drag on a beat mark acts as a plain strip press (the playhead moves there).
- Backspace deletes the hovered placed beat (no click needed). Computed beats can't be deleted
  (beep). A deleted beat's time signature moves to the next placed beat after it (the first
  placed beat when the deleted beat was the first), unless that beat has its own.
- During playback beat marks can't be grabbed or deleted (the strip behaves as in milestone 5).

Recomputation, after every change of the placed beats (place, drag, delete): delete all computed
beats, set every `firstBeat: computed` to `no`, then:

```
If there are fewer than 2 placed beats, stop here.
current_bpm = none
for each pair of adjacent placed beats (b1, b2):
    if current_bpm is not none:
        insert N computed beats between b1 and b2, evenly spaced; N ≥ 0 minimizes
        abs(log(current_bpm / result_bpm)) with result_bpm = (N + 1) · 60 / (time(b2) − time(b1))
        (ties: the smaller N)
        current_bpm = result_bpm
    else:
        result_bpm = 60 / (time(b2) − time(b1))
        if result_bpm ≥ min_reasonable_bpm: current_bpm = result_bpm
if current_bpm is not none:
    insert computed beats after the last placed beat, every 60 / current_bpm s, up to the end of
    the file
current_time_signature = none
beat_in_bar = 1
for each beat (computed and placed) in order:
    if beat.timeSignature: current_time_signature = beat.timeSignature
    if current_time_signature is none: continue
    if beat.firstBeat == placed: beat_in_bar = 1
    elif beat_in_bar == 1: beat.firstBeat = computed
    beat_in_bar = beat_in_bar mod beats_per_bar + 1
```

`beats_per_bar` = ⌈time signature ÷ `beat_note`⌉, computed with exact fractions (4/4 → 4, 3/4 →
3, 6/8 → 3, 5/8 → 3, 7/8 → 4). Computed beat positions are rounded to the nearest sample. Beats
loaded from a sidecar file are shown as stored (no recomputation until the first change).

Saving: after every change (on release for a drag) the beats, placed and computed, are written
to the sidecar file (milestone 6 format, `timeSignature` left out when absent), replacing it
atomically. If writing fails, an alert ("Could not save beats") names the file and the reason;
the beats stay in memory.

### Spectrogram (from milestone 8)

View modes of the main pane: waveform (milestones 2–7) and spectrogram. The navigator always shows
the waveform.

Controls, floating over the main pane's top-right corner on a small translucent background, in
both orientations (right to left):

- A dropdown: Waveform / Spectrogram.
- Spectrogram mode only:
  - A small spinning progress indicator, shown while the background computation is working.
  - The window length slider: 10 ms … 500 ms, logarithmic, with a readout in ms.
- One column per point along the time axis and one row per point across it (screen points, not
  physical pixels). (A Retina toggle computing per physical pixel was removed after milestone 8:
  it made no visible difference.)
- The mode and the window length are remembered across launches. Defaults: waveform, 50 ms.
- With no file loaded the controls are hidden.

Everything else in the main pane stays as in waveform mode: the selection band, the playhead and
last-start lines (the pointer line stays in the strip, as before), and all mouse and keyboard behaviour (selection, line drags,
seeking, B / Shift+B, pan, zoom). The ±50 ms margins and the time outside the file are blank.

Computation (a short-time Fourier transform of the mono mix, the signal the waveform shows):

- Window: a Gaussian, MATLAB's default `gausswin(N)`:
  w[k] = exp(−½ · (α · k / ((N − 1) / 2))²), k = −(N − 1)/2 … (N − 1)/2, α = 2.5.
  Its standard deviation is (N − 1) / (2α) samples. It is set to half of the slider value L, so
  N is the odd integer nearest to 2.5 · L · fs + 1, ties to the larger (L in seconds, fs the sample rate; the nonzero
  part of the window is 2.5 × L). A window wider than the FFT is cut to its central 65,535
  samples (only above about 52 kHz at the longest windows).
- Columns: one per time pixel (point). Pixel i of a pane with time-axis length
  P pixels covers the times from start + i · (end − start) / P to start + (i + 1) · (end − start)
  / P; its window is centred at the sample nearest to the middle of that span. Columns whose
  centre is outside the file are not drawn. Samples outside the file count as zero.
- FFT: 65,536 points, the windowed samples zero-padded. The magnitude |X| is read at each row's
  frequency f by linear interpolation between the bins at f · 65536 / fs.
- Level: 20 · log10(|X| / (Σw / 2)) dB, so a full-scale sine reads 0 dB, plus the amplitude
  zoom (0 … +60 dB, ⌘ + scroll across the time axis as before). The range −60 … 0 dB maps onto
  the magma colour map (dark is quiet); values outside it are clipped to its ends.

Frequency axis:

- Logarithmic: MIDI note m is at 440 · 2^((m − 69) / 12) Hz. The axis covers A0 (note 21)
  minus half a semitone to C9 (note 120) plus half a semitone: 100 semitones, each note centred
  in its semitone.
- Direction: horizontal mode, low notes at the bottom; vertical mode, low notes at the left.
- Fixed scale: 14 points per semitone (wide enough for a small two-character label such as "A4"
  for the later note grid). No frequency zoom. Rows: one per pixel across the time axis; each
  row's frequency is the one at the pixel's centre.
- The pane shows a part of that range, the frequency view. Option + drag and middle-button drag
  across the time axis pan it (the grab moves along the time axis as before and across it at the
  same time). It stops at the range's ends. If the pane is larger than the whole range, the range
  is centred and the rest is blank.
- Initially the view is centred on C4 (note 60). The frequency view is kept when switching modes
  and opening files, not across launches.

Whole-pixel panning (both modes): every pan moves the view by a whole number of pixels (points),
so cached columns can be reused exactly.
This covers scrolling, Option/middle drag (both axes), the scrollbar (drag and click) and follow.
The left-over fraction is carried to the next pan of the same gesture or input, so slow scrolling
still moves. At the view limits the view stops exactly at the limit. Zooming, resizing and the
other view changes (Zoom Out Full, Zoom to Selection, opening a file) stay continuous.

Background computation and cache:

- Columns are computed on a background thread; the newest request supersedes older ones.
- A computed column holds the levels (before the amplitude zoom) for every pixel row of the
  whole frequency range. It is reused when the window length, the time scale, the orientation and
  the pane size are unchanged: after a pan only the newly visible columns are computed; a
  frequency pan and an amplitude zoom compute nothing.
- Zooming, resizing, switching orientation: until the new columns are ready, the
  previous image is shown stretched and shifted to the new mapping.
- Moving the window length slider invalidates the whole cache.
- The cache keeps the visible columns plus one pane length on each side; nothing is computed
  ahead of need.

### Spectrum and piano keys (from milestone 9)

Spectrum pane (spectrogram mode with a file loaded only):

- Placement: it lies over the main pane's left side in horizontal mode (120 points wide, the
  main pane's full height) and over its bottom in vertical mode (120 points tall, the main pane's
  full width), separated from the spectrogram by a 1-point separator line.
- The navigator keeps its full size, and the main pane keeps its size and its time axis: the
  spectrogram's time axis stays aligned with the navigator's, and the spectrum pane simply covers
  the first 121 points (horizontal) or the last 121 points (vertical) of the visible range.
  The selection band, the playhead and the last-start line are hidden where they are covered.
- Frequency axis: exactly the spectrogram's (same rows, 14 points per semitone, low notes at the
  bottom / left, the same frequency view, so it follows the frequency pan).
- Content: the spectrogram's level column at the playhead: the same computation as a spectrogram
  column (window, FFT, interpolation, level formula, amplitude zoom, −60 … 0 dB range), with the
  window centred at the sample nearest to the playhead. It follows the playhead (also during
  playback), the window length slider, the amplitude zoom and the frequency pan.
- Drawing: a filled curve (the accent colour, translucent fill, 1-point line), one point per
  row. The level grows from the left edge rightwards (horizontal) or from the bottom edge upwards
  (vertical); −60 dB (and below) is at that edge, 0 dB (and above) at the opposite edge.
- Piano keys, drawn over the curve as outlines only (no filled keys), in a translucent label
  colour, 1-point lines:
  - Each key spans exactly its own semitone on the frequency axis (so the keys line up with the
    spectrogram rows); the keys cover the whole range A0 … C9 and are clipped to the pane.
  - Along the amplitude axis the keys fill the pane. Back end: the left edge (horizontal) or the
    top edge (vertical), common to all keys. White keys run to the opposite edge (the
    spectrogram side in horizontal mode, the bottom in vertical mode); black keys run 63 % of
    that length from the back end (a real piano's ≈ 95 / 150 mm).
  - Black keys: a rectangle over their semitone. White keys: the boundary between E|F and B|C is
    the semitone edge over the full length; between other neighbouring white keys it is the
    middle of the black key between them, from the black key's end to the front end. (So C, E, F
    and B are 1.5 semitones wide, D, G and A 2 semitones; the lowest A and the highest C are
    bounded by the range's edges.)
  - An outline around the whole keyboard (the range's edges and the back and front ends).
- Everything is clipped to the pane's bounds.
- Mouse: presses on the spectrum pane do nothing (they don't reach the spectrogram under it).
  Over the pane the cursor is the arrow and there is no pointer line; a drag that started on the
  spectrogram continues when the pointer moves over the spectrum pane.
- Known limitation (experiment): follow, Zoom to Selection and the other view changes don't know
  about the covered part, so the playhead or the selection can end up under the spectrum pane.

Analysis window in the navigator (spectrogram mode only): the spectrogram's window function
(the Gaussian of N samples, see "Spectrogram") is drawn over the navigator's waveform, centred at
the sample nearest to the playhead, spanning N samples along the time axis in the navigator's
mapping. It is mirrored like the waveform (+w and −w around the zero line), scaled so its peak
touches both edges of the pane; the curve starts and ends on the zero line. Orange, 1.5-point
lines. It follows the playhead, the window length slider and the navigator's view.

Command-scroll zoom picks one axis per gesture: the first event of a trackpad scroll gesture
(scroll phase "began") decides, by the larger absolute delta, whether the whole gesture
(including its momentum) zooms time or amplitude; the other axis' deltas are ignored. A wheel
without gesture phases decides on every event.

### Loading audio files

- File → Open… (⌘O) shows the standard open dialog, limited to audio files. This is the only way to
  open a file (no drag and drop, Open Recent or Finder/Dock opening).
- Supported formats: whatever AVFoundation can decode (WAV, AIFF, CAF, MP3, AAC/M4A, ALAC, FLAC).
- The whole file is decoded into memory: all channels, at the file's own sample rate, as 32-bit
  float.
- Loading is blocking: the UI is unresponsive while the file is decoded.
- If a file can't be opened or decoded, an alert shows the reason, and the previously loaded file
  (if any) stays loaded.
- Known limitation: at most 2³⁰ − 1 sample frames (about 6 h 45 min at 44.1 kHz, 6 h 12 min at
  48 kHz). Longer files show an alert stating the file's duration and the maximum at its sample
  rate. (AVAudioPCMBuffer stores each channel's byte size in 32 bits, so a Float32 buffer can't
  hold more frames; the machine's memory isn't the limit.)

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
button states, and the scrollbar's frame and knob position/proportion. From milestone 4 on, also:
the dump adds the playback state (playing, playhead, rewind point, last start, loop, follow,
I/O buffer size, latency, display refresh rate); the command `record <path>` / `record stop`
writes what the source node renders (the app's output before the system mixer) to a float WAV
file. From milestone 5 on, also: the dump adds the navigator's strip frame and its ticks
(time, axis position, major/minor, label text and label frame). From milestone 6 on, also: the dump adds the
loaded beats, the strip mode (beats/time) with the toggle's state and enablement, the strip's beat
marks (time, kind, bar number, label frame) and the pointer line's axis position; the command
`beats on|off` sets the toggle through the same code path as the button. From milestone 7 on, also:
the dump adds the computed constants, the beep count, the time signature dialog (shown,
pending), and the strip's hovered beat; commands `beatkey [shift]` (B / Shift+B through the key
handler's code path), `tsdialog <n>/<d>|dontset` (answers the dialog through its buttons' code
path). From milestone 8 on, also: the dump adds the main pane's mode, the window length, N, the
frequency view (lowest and highest visible semitone positions, points per
semitone), the busy flag, and the counts of computed and cached columns (computed: FFTs run since
launch); commands `mode waveform|spectrogram`, and `window <ms>` (through the
controls' code paths), `specdelay <ms>` (slows each background step, to observe the busy state),
`scrollpan <dx>,<dy>` (a plain scroll's
pan in the main pane, with fractional points), and `specdump <path>`, which writes the current image's levels in dB
(before the amplitude zoom and the clipping) with each column's centre sample and each row's
frequency, as JSON with a little-endian float32 matrix. From milestone 9 on, also: the dump adds the spectrum
pane (shown, frame, centre sample, first row and row count, the levels of its visible rows in dB
before the amplitude zoom, and the key outline lines as drawn, in pane coordinates), the
navigator's analysis window polyline (shown, points), and the zoom axis chosen for the current
⌘-scroll gesture. From milestone 2 on, `--snapshot` captures the real window, including the toolbar, by running
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
- (Milestone 3 review) Amplitude zoom rate: the same as time zoom, e^(0.01·d) for a scroll of
  d points (100 points ≈ 8.7 dB). It applies to both panes, like the time range. There is no
  on-screen readout of the amplitude zoom yet (it is in the state dump).
- Selection edge grab distance: 4 points. Where both edges are within reach (a very narrow
  selection), the nearer one is grabbed.
- MP3 and AAC files usually start with encoder padding (tens of milliseconds of real zero
  samples). These are part of the decoded file, so they are drawn as a flat waveform line, not as
  margin.
- (Milestone 4) The audio engine starts at the first playback and keeps running (rendering
  silence while stopped), so starting playback has no engine start-up delay.
- The render callback and the main thread share the playback state under a lock (not real-time
  safe; fine for the prototype). The render block is created outside the main actor: Swift 6
  checks actor isolation at run time and would trap on the audio thread otherwise.
- The display refresh rate is `NSScreen.main.maximumFramesPerSecond` (on the development
  machine's display: 100 Hz, giving a 30 ms buffer = 1440 frames at 48 kHz; the measured output
  latency was 30.6 ms).
- Playhead: a 1.5-point red line (system red) in both panes, a 2-point red mark on the scrollbar
  track. Transport icons (SF Symbols): `backward.end.fill`, `play.fill` / `stop.fill`,
  `arrow.counterclockwise`, `repeat`; follow button: `scope`.
- Space, Left and Right Arrow work only without Command, Option, Control or Shift; they are
  handled by the app-wide key monitor, so they don't reach focused buttons.
- Follow eases the playhead's offset from the view center while moving the center along with the
  playhead. (Until the milestone 4 review it eased only the offset, which left the playhead
  about one time constant, 0.5 s, ahead of the center.)
- `verify_m3.py`'s toolbar check allows the Follow Playhead button added in milestone 4.
- (Milestone 4 review) A playhead outside the view engages follow at once (otherwise a playhead
  before the view would stay off-screen until it walks in).
- "Expected end in the view" also requires the loop start in the view when looping, since the
  playhead returns there; with only the end visible, follow engages as usual.
- Lines at the same time (within one sample) move together for every combination, not only the
  selection start with the playhead: e.g. during a looping playback started with
  rewind-and-play, the last start sits on the selection start, and dragging that edge keeps both
  aligned (play-again then matches rewind-and-play). When the playhead is grabbable, it and the
  last start usually coincide anyway (each direct playhead change sets the last start).
- Grab priority: the nearest line wins; with exact ties, the order is selection start, selection
  end, playhead, last start (only matters for which edge is taken when both are in reach).
- Last-start color: system red in sRGB with 35% of its saturation and 90% of its brightness.
- The file-end stop still rewinds the playhead to the file start (continuing from the file end
  would play nothing).
- Down Arrow follows the same modifier rule as Space, Left and Right.
- `verify_m3.py` criterion 5 moves the playhead away before its navigator drag: since the
  milestone 4 review the playhead line at the drag start would be grabbed instead.
- Time-marker strip (milestone 5): a mode of the waveform pane view (`WaveformNSView.isRuler`), so
  it shares the time mapping, scrolling, pinch and Option/middle-drag pan with the navigator. Same
  background as the navigator, a 1-point separator line along the waveform side. Labels: 10-point
  system font with monospaced digits, secondary label color, 3 points right of (below) the tick,
  vertically centred in the horizontal strip. Major ticks span the strip; minor ticks are 4 points
  long at the waveform side. A label that would leave the strip is not drawn (its tick is).
- The vertical strip's width comes from the file's duration formatted with 3 decimals (the longest
  possible label) plus 8 points, so it changes only when a file is opened.
- Step choice uses the width (horizontal) or height (vertical) of the label of the last visible
  time at that step; with monospaced digits that is the widest label in view.
- A click without a drag on the last-start line in the strip acts like a plain strip press
  (playhead there, or playback jumps there).
- The state dump's `waveforms` leaves out the strip (it has no waveform); it is under `ruler`, and
  in `screenFrames` as `ruler`. The playback dump also has `clearPoint`. The input driver gained
  `down` / `dragto` / `up` for drags with dumps in between.
- (Milestone 6) Show Beats toolbar icon: `metronome`. Small ticks and dots use the minor time tick
  colour; a dot is 3 points in diameter, centred where a small tick's middle would be; a dotted
  big tick is drawn with 2-point dashes and 2-point gaps.
- Pointer line: 1 point, system grey (secondary label colour), drawn above the ticks and below the
  playhead and last-start lines.
- Unknown keys in a sidecar beat entry are ignored (room for later fields). A time signature is
  `n/d` with n ≥ 1 and d one of 1, 2, 4, 8, 16, 32, 64 (128 from milestone 7).
- The state dump's menu items carry `enabled` and `checked`; the dump refreshes each menu first
  (`menuNeedsUpdate`), because SwiftUI updates menu items only when a menu is about to open. The
  input driver's `key` command accepts `b` and modifiers (for ⌘B).
- (Milestone 7) Beat grab distance in the strip: 4 points, like the lines. Where a beat mark and
  the last-start line are both in reach, the beat wins.
- Beat cursor: open hand, closed hand while dragging.
- Placing at the pointer uses the pointer line's time (the pane's mapping), so B over the main
  pane and over the navigator at the same axis position gives the same sample.
- (Milestone 8) Points per semitone: 14 in both orientations (a 10-point "A4" is about 13 points
  wide and 12 points tall). A single constant, to be tuned with the note grid.
- Frequency view initially centred on C4.
- Spectrogram controls are hidden with no file loaded.
- Colour map: magma (perceptual, dark for quiet), interpolated from 11 anchor colours.
- The window length's odd-number rounding takes the larger one on a tie (500 ms at 44.1 kHz:
  2.5 · 0.5 · 44100 + 1 = 55,126 → 55,127).
- The FFT runs in double precision (vDSP), one worker per core; columns arrive in steps of 48.
- Synthesized scroll events reach the app with whole-point deltas only, so the fractional-scroll
  checks use the `scrollpan` hook (the scroll handler's own pan code).
- (Milestone 9) Spectrum pane thickness: a fixed 120 points (not resizable); a constant, like
  the black key length (63 % of the white keys).
- The spectrum pane is an overlay on the main pane rather than a split, so the main pane, the
  spectrogram cache and the whole-pixel pan grid are unchanged; the covered columns are still
  computed.
- Spectrum level direction: rightwards / upwards from the keys' back end (horizontal) or the
  pane's bottom (vertical), the natural reading in each orientation (not a rotation of one layout).
- The spectrum column is computed on the main thread at each playhead move (one 65,536-point
  FFT); the last result is cached by (file, window length, sample).
- The spectrum view sets `clipsToBounds`: since macOS 14 views don't clip their drawing by default,
  and the key outlines spilled onto the neighbouring panes.
- Verification: the input driver's `scrollp x y dx dy phase [flags]` posts a continuous scroll
  event with a gesture phase (1 began, 2 changed, 4 ended); macOS passes the phase on to NSEvent.
