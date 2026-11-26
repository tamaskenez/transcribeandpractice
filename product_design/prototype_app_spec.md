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
- Drawing (from milestone 10; before: an interpolated polyline, which aliased when zoomed out):
  min/max/RMS columns. A pane with a time-axis length of L points has L columns, one per point
  along the time axis (screen points, not Retina pixels). Column j covers the time slice
  [start + j·h, start + (j+1)·h], h = (end − start)/L, and the point j…j+1 on the time axis.
  - Value set of a column: the mono samples whose positions lie inside the slice, plus the
    linearly interpolated signal at the slice's two edges. Neighbouring columns share an edge
    value, so they always touch; zoomed in so far that a column holds no sample, it shows the
    interpolated line.
  - Only the part of the slice within the file (sample positions 0 … frames−1) counts; a column
    entirely outside the file (in the margins) is not drawn.
  - Min/max bar: from the column's minimum to its maximum, in the accent color, at least 1 point
    thick across the time axis (a silent stretch still shows the flat line).
  - RMS marks: the two endpoints of the span −rms … +rms around the zero line, rms = √(mean of
    the squares of the value set), each 1 point thick, in a lighter tint of the accent color,
    drawn over the min/max bar (zoomed out they form two thin lines). Not drawn when a column
    covers 1 ms or less, nor where rms is 0. (Changed in the milestone 10 review: first a
    filled bar from −rms to +rms, which hid the waveform when zoomed in.)
  - The amplitude zoom multiplies all three values; the bar and the marks are clipped at the
    pane edges (a mark outside the pane isn't drawn).
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
  (Changed in milestone 10: in horizontal mode a negative vertical delta (two fingers moved up,
  with natural scrolling) zooms amplitude in; vertical mode is unchanged.)
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

- Each loaded file has a list of beats, sorted by position, at most one per sample. Every beat is
  put there by the user; the app never adds beats (milestone 7's computed beats were removed in
  milestone 12). A beat has:
  - `sample`: its position, a sample frame index of the file (0 ≤ sample < frame count).
  - `timeSignature` (optional): e.g. `4/4`, `3/4`, `6/8`. A beat with one changes the time
    signature there (and starts a bar); a beat without one continues the previous (see "Bars").
  - `firstBeat` ("beat within bar", from milestone 12): `auto` (the beat's place in its bar is
    counted) or `start` (the beat starts a bar).
- The beats are stored in the session file with the notes (see "Session file"; until milestone 12
  in a `.beats.json` sidecar, which is no longer read).
- Opening another audio file replaces the beats with that file's.

Display (the navigator's marker strip):

- Beats mode shows the beats instead of the time ticks; time mode shows the time ticks of
  milestone 5. Toolbar toggle "Show Beats" and View → Show Beats (⌘B, with a checkmark) switch
  between them. Beats mode is the default; the choice is remembered across launches. While the
  loaded file has no beats (or no file is loaded), the button and the menu item are disabled and
  the strip shows time, but the stored choice is kept.
- Each beat is drawn at its sample's time, in the same mapping as the time ticks:
  - Bar start with a bar number: a big tick (the full strip thickness, like a major time tick)
    with the bar number as its label (placed like the time labels: right of the tick in
    horizontal mode, below it in vertical mode). The big tick is solid at a forced bar start
    (`firstBeat: start` or a time signature) and dotted at a counted one.
  - Other beats: a small tick (as long as a minor time tick).
- Bar numbers come from the bar layout (see "Bars"): bar 1 is the first forced bar start, earlier
  bars are 0, −1, … The beats of a partial bar at the start of the file have small ticks and no
  number.
- Crowding (zoomed out):
  - Bar numbers are shown on every k-th bar (bars 1, 1 ± k, 1 ± 2k …), with k the smallest of 1,
    2, 4, 8 … at which neighbouring numbered bars in the visible range keep at least 30 points
    between their labels (as for the time labels). The other bar starts are drawn as other beats
    (small tick).
  - Small ticks are drawn for all beats if neighbouring beats in the visible range are at
    least 4 points apart; otherwise only for the un-numbered bar starts if those are at least
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

### Placing and editing beats (from milestone 7, reworked in milestone 12)

Constants (not on the UI yet): `beat_note` = 1/4 (a rational number: the note value BPM refers
to), `max_reasonable_bpm` = 240. The minimum distance between beats is 60 / `max_reasonable_bpm`
= 0.25 s.

Placing (keyboard; plain B and Shift+B, no Command / Option / Control):

- B places a beat (`firstBeat: auto`) at the sample under the mouse pointer, while the
  pointer is over the navigator waveform, the time-marker strip or the main pane (the pointer
  line's time, rounded to the nearest sample). During playback it uses the playhead instead of
  the pointer (wherever the pointer is).
- Shift+B does the same with `firstBeat: start`.
- Refused, with a system beep and no change: no file loaded; the pointer not over those panes
  (when stopped); the time outside the file; another beat closer than 0.25 s; the time inside
  the beats a note uses (milestone 13, see "Notes").
- No dialog (milestone 7's time signature dialog for a new first beat is gone: the default is 4/4).
- Works in both strip modes (the beats are placed even while the strip shows time).
- Time signatures with a denominator up to 128 are valid.

Beats in the strip are edited in beats mode while stopped. During playback beat marks can't be
selected, moved or deleted and there is no beat context menu (the strip behaves as in
milestone 5).

Selection (a list of selected beats, cleared when another file is opened):

- A plain click (no drag) on a beat mark (within 4 points along the time axis) selects only that
  beat. A plain click on the strip away from the beat marks clears the beat selection and acts
  as a plain strip press (the playhead moves there).
- ⌘-click on a beat mark toggles it; a beat selected this way (or by a plain click) becomes the
  anchor.
- ⇧-click on a beat mark adds all beats from the anchor to that beat (inclusive) to the
  selection; without an anchor it selects only that beat (and makes it the anchor).
- Escape clears the beat selection (if there is one; otherwise it clears the time selection as
  before).
- Beats in a range are selected even where crowding hides their marks.
- Selected beats are drawn in the strip only: a 3-point line in the accent colour with a 1-point
  white border on both sides, across the strip, also where crowding hides their marks (dark mode;
  light-mode colours later).

Cursor and moving:

- No beats selected: over a beat mark the cursor is the left-right resize arrow (up-down in
  vertical mode), also while dragging; dragging the beat moves only that beat. This takes
  precedence over the last-start line's grab there.
- Beats selected: anywhere in the strip the cursor is an open hand (closed while dragging); a
  drag starting anywhere in the strip moves all selected beats by the same amount (the pointer's
  time change). The last-start line can't be grabbed in the strip then.
- A move is limited so that no moving beat comes closer than 0.25 s to a beat that doesn't move
  (the order of the beats never changes, also with unselected beats between selected ones), and
  no beat leaves the file. It is not limited to the visible range (selected beats may be off
  screen). `firstBeat` and `timeSignature` move with their beats.
- The bars are recomputed live while dragging; the result is saved on release.

Deleting:

- Backspace deletes the selected beats; without a selection, the beat whose mark is under the
  pointer (no click needed).
- A deleted beat's time signature is dropped (the following bars inherit the previous one).
- (Milestone 13) Beats a note uses can't be deleted: if any of the beats to delete is one, a
  system beep and nothing is deleted (also for a selection with only some such beats).

Context menu (right-click):

- Right-click on a beat mark that is not selected selects only that beat; with beats selected, a
  right-click anywhere in the strip opens the menu for the selection. Without a selection (and
  not on a beat mark) there is no menu.
- One beat selected:
  - Section "Beat within bar", two mutually exclusive items (the current one checked):
    "Auto (<n>)", where <n> is the ordinal (1st, 2nd, 3rd, 4th … 11th, 12th, 13th, 21st …) the
    beat would have in its bar if it were `auto`, and "Start bar (1st)". They set `firstBeat`.
    A beat with a time signature starts a bar either way, so its Auto item reads "Auto (1st)".
  - "Time signature…" (opens the dialog below).
  - "Delete".
- Several beats selected:
  - "Subdivide…" (opens the dialog below; disabled unless two neighbouring beats are both
    selected).
  - "Equalize beats within bars" (disabled unless it would change something, see below).
  - "Delete".

Time signature dialog (modal sheet): a popup "Continue" / "Change", a numerator text field
(digits only) and a denominator popup (1, 2, 4 … 128), Cancel and OK.

- Prefilled with the beat's own time signature and "Change" if it has one; otherwise with the
  inherited one (the signature in effect at the beat if it set none) and "Continue".
- Switching to "Continue" resets the fields to the inherited signature. Changing the numerator
  or the denominator while on "Continue" switches to "Change" (if the value differs from the
  inherited one).
- OK with "Change" (numerator ≥ 1, otherwise OK is disabled) sets the beat's time signature (the
  beat then starts a bar); OK with "Continue" removes it. Cancel changes nothing.

Subdivide dialog (modal sheet): "Split each gap into [n] parts", the allowed range, Cancel and OK.

- A gap is two neighbouring beats (no beat between them) that are both selected. Each gap
  becomes n equal gaps: n − 1 new beats (`firstBeat: auto`, not selected) evenly spaced in it,
  rounded to the nearest sample. Bars are not considered (a bar may then be cut short, see
  "Bars").
- n is 2 or more and at most the largest value keeping the new beats 0.25 s apart in every gap
  (shown in the dialog; OK disabled outside the range).
- (Milestone 13) If a gap lies inside the beats a note uses: a system beep, and the dialog
  doesn't open.

Equalize beats within bars: selected beats that don't start a bar are ignored. For every bar
whose start and the next bar start are both selected, the beats between the two are moved to
equal spacing (rounded to the nearest sample); the bar starts stay.

Saving: after every change (on release for a drag) the session file is written (see "Session
file").

### Bars (from milestone 12)

The bar layout is computed from the beats whenever they change (it is not stored).

- A forced bar start is a beat with `firstBeat: start` or with a time signature.
- The default time signature is 4/4. `beats_per_bar` of a signature = ⌈signature ÷ `beat_note`⌉,
  with exact fractions (4/4 → 4, 3/4 → 3, 6/8 → 3, 5/8 → 3, 7/8 → 4).
- Bar 1 starts at the first forced bar start, or at the first beat if there is none. Its time
  signature is the one set there, else 4/4.
- Beats before bar 1 are counted backwards in bar 1's signature: the beat just before it is the
  last beat of bar 0, and so on (bars 0, −1, …); the earliest bar may be partial (its first
  beats missing), and then it has no bar start.
- From bar 1 on, each bar starts at a beat with the signature set there or, if none, the previous
  bar's. It lasts `beats_per_bar` beats, but ends early at the next forced bar start. The next bar
  starts after it (at the forced start, or counted: an automatic bar start).
- Effective time signature (per bar, computed on demand; to be displayed later): the bar's
  signature, or, for a bar cut short to k beats, k · `beat_note` written in the signature's
  denominator if that is exact (6/8 cut to 2 beats → 4/8; 4/4 cut to 1 beat → 1/4), else in the
  `beat_note`'s (2/2 cut to 1 beat → 1/4). Inherited signatures continue from the bar's own
  signature, not from the effective one. A bar cut off by the end of the beats keeps its
  signature.
- Example: two 4/4 bars, each starting with `firstBeat: start`; subdividing a gap in the first
  gives a 4/4 bar, a 1/4 bar, and the second 4/4 bar.

### Spectrogram (from milestone 8)

View modes of the main pane: waveform (milestones 2–7) and spectrogram. The navigator always shows
the waveform.

Controls, floating over the main pane's top-right corner on a small translucent background, in
both orientations:

- Top row (right to left): a dropdown Waveform / Spectrogram; in spectrogram mode also the Grid
  control and the Harmonics dropdown (milestone 13, see "Editor grid" and "Notes").
- Spectrogram mode only, a second row below it, right-aligned (milestone 13; before: in the top
  row, left of the dropdown): the window length slider (10 ms … 500 ms, logarithmic), its
  readout in ms, and a small spinning progress indicator, shown while the background
  computation is working.
- One column per point along the time axis and one row per point across it (screen points, not
  physical pixels). (A Retina toggle computing per physical pixel was removed after milestone 8:
  it made no visible difference.)
- The mode and the window length are remembered across launches. Defaults: waveform, 50 ms.
- With no file loaded the controls are hidden.

Everything else in the main pane stays as in waveform mode: the selection band, the playhead and
last-start lines (the pointer line stays in the strip, as before) and the keyboard (B / Shift+B).
The ±50 ms margins and the time outside the file are blank.

Mouse over the spectrogram (milestone 13; until then as in waveform mode): it never changes the
playhead, the last start or the selection. Plain presses and drags don't select, seek or grab
lines (the cursor stays the arrow, also over those lines); ⇧/⌘/⌃-clicks do nothing. Pan
(Option-drag, middle-drag, scroll) and zoom (⌘-scroll, pinch) work as before. A plain click
places a note (see "Notes").

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

### Editor grid (from milestone 11)

Bar, beat and grid lines across the main pane, at right angles to the time axis (along the
frequency axis in spectrogram mode), spanning the whole pane.

Which lines:

- Bar lines at the bar starts (forced or counted, see "Bars"; before milestone 12: the downbeats),
  beat lines at the other beats. Both in waveform and spectrogram mode, independent of the
  Show Beats toggle. Not in the navigator.
- Grid lines only in spectrogram mode, and only while the Grid panel is open (milestone 13;
  before: while the Grid lines checkbox was on). A line every grid step, 1/n of a whole note
  (the Grid value), from each bar start until it reaches or passes the next bar start; in the
  last bar until the last beat; in the beats before the first bar start (a partial first bar)
  counted backwards from that bar start down to the first beat (milestone 13; before: no grid
  there). Grid lines that fall exactly on a beat are left out (the beat or bar line is there).
- Grid timing, piecewise through the beats: each beat interval counts as one `beat_note` (1/4).
  A grid line at musical position p beats after the bar start (p = k · (1/n) / `beat_note`,
  k = 1, 2, …, exact fractions) lies in the interval from beat ⌊p⌋ to beat ⌊p⌋ + 1 of the bar,
  at the fraction p − ⌊p⌋ of it (linear in time). So the grid follows tempo changes and a bar
  whose last beat is short (5/8 has 3 beats) still gets a grid over all its beats.
- Crowding: if two neighbouring visible lines (all kinds) are closer than 6 points, the grid
  lines are hidden; then if two neighbouring bar/beat lines are closer than 6 points, the beat
  lines are hidden; then if two bar lines are closer than 6 points, the bar lines are hidden.

Drawing (dark mode; a light-mode color scheme is to be designed later, until then the same
colors are used):

- Bar and beat lines have a white 50 % opaque core and a 1-point black 50 % opaque border on both
  sides. Core width: bar 3 points, beat 1 point. The core is aligned to whole points (its start
  rounded to the nearest point).
- Grid lines (milestone 13; before: dotted like the others): 1 point wide, centred on a whole
  point, in the "moving dashes" style: alternating 4-point dashes of 50 % black and 50 % white
  that move along the line by 0.5 point every 1/16 s (8 points per second), visible on any
  background. The dashes move only while something in this style is drawn (grid lines or the
  hover cell); otherwise the timer stops.
- Spectrogram mode: over the spectrogram, under the selection band, the playhead, the
  last-start and the pointer lines. Waveform mode: over the waveform, under those lines.

The Grid control (from milestone 13 in the spectrogram controls, left of the View dropdown;
before: in the toolbar; shown only in spectrogram mode):

- A "Grid 1/n" button (showing the current value) that opens a small panel (the grid lines are
  shown while it is open; milestone 11's "Grid lines" checkbox is gone):
  - Radio buttons: Straight, Triplet, Tuplet.
  - Straight: a list 1/1, 1/2, 1/4, 1/8, 1/16, 1/32, 1/64; Triplet: 1/3, 1/6, 1/12, 1/24,
    1/48; the current value has a checkmark, clicking a value selects it.
  - Tuplet: "1 / [ ]", a text field taking a whole number 1 … 64; other input is ignored (the
    value stays the last valid one).
- Each kind keeps its own value; switching the kind switches to that kind's value. Defaults:
  Straight, 1/16 (Triplet 1/12, Tuplet 1/5). All of it is remembered across launches.

### Notes (from milestone 13)

Notes are drawn into the spectrogram on the editor grid, like MIDI notes over a piano roll.

Hover cell (spectrogram mode, while the pointer is over the spectrogram and not over the spectrum
pane):

- A rectangle in the moving dashes style (see "Editor grid") around the grid cell under the
  pointer, drawn above everything else in the pane.
- Time: one grid step (1/n note, n the Grid value), counted from the bar start, cut at the next
  bar start (a 1/2 grid in a 3/4 bar: a half note, then a quarter note); in the partial first
  bar counted backwards from the first bar start and cut at the first beat; in the last bar cut
  at the last beat. Beat lines don't split a cell. Positions are exact fractions of beats (the
  grid timing of "Editor grid"). Before the first and after the last beat there is no cell.
- Pitch: from the boundary below the note under the pointer to the one above it (note − ½ …
  note + ½), MIDI notes 21 … 120 (the spectrogram's range).
- The cell's lines are at whole-point centres; the grid lines and the hover cell use the grid
  whether or not its lines are shown (the Grid panel open or not, crowding).
- Harmonics dropdown (spectrogram controls, left of the Grid control): 1 … 5, default 1,
  remembered across launches. With h > 1 the hover cell is repeated 12 · log2(i) semitones higher
  for i = 2 … h (+12, +19.02, +24, +27.86), same size and style. Only drawn: it doesn't affect
  placing. Drawing is clipped to the main pane.

Placing: a plain click (no drag) on the spectrogram places a note in the hover cell: a single
segment at the cell's note (see the model below: one point with pre = post = end pitch = the
note, at the cell's start; the end at the cell's end). Clicking where the same note already is
adds nothing. A drag, an Option-click (pan) and ⇧/⌘/⌃-clicks place nothing. (Editing,
deleting and multi-segment notes come in the next milestone.)

Model (note trajectories):

- A grid location is a beat and τ, an exact fraction 0 ≤ τ < 1: the time τ of the way from that
  beat to the next one (linear in time). τ > 0 needs a next beat.
- A note trajectory is a sequence of one or more points and an end. A point has a grid location,
  a pre-pitch and a post-pitch; the end has a grid location and a pitch. The locations strictly
  increase. Pitches are MIDI note numbers (fractional values between semitones). A trajectory
  of N − 1 segments has N locations; two neighbouring locations may be many beats apart.
- Pitch over time (computed, not stored; used for drawing from the next milestone): linear in
  MIDI note numbers (logarithmic in frequency) from a point's post-pitch to the next point's
  pre-pitch (or the end pitch), over beat positions. Around a point with pre ≠ post the pitch
  goes linearly from pre to post in a transition just before the point, taking
  min(`beat_note`/8, preceding segment / 8) from the preceding segment (in beats: at most 1/8
  beat); at the first point (no preceding segment) the transition takes `beat_note`/8 before
  the point, so the note starts sounding earlier. A point with pre = post has no transition.
- Notes follow their beats: moving a beat moves the notes' locations on it. A note uses the beats
  from its first point's beat to the beat at or after its end (the end's beat, or the next one if
  its τ > 0); those can't be deleted, and no beat can be inserted between them (B, Subdivide; see
  "Placing and editing beats"). Notes may overlap.
- The notes are cleared when another file is opened (replaced by that file's).

Drawing (spectrogram mode only; notes have a constant pitch in this milestone):

- A note's area spans its start to its end in time and pitch − ½ … pitch + ½, with the edges
  rounded to whole points, so the areas of neighbouring notes touch without overlapping.
- In it: a capsule along the time axis (semicircles of the area's cross size at both ends; an
  ellipse filling the area when it is shorter than that), drawn as a black 1-point outline and a
  white one over it offset by (−1, −1) (light from the top left of the screen, in both
  orientations). Each is one point smaller than the area, so the two together fill it exactly.
  No fill: the spectrogram stays visible inside.
- Over the spectrogram, the editor lines, the selection band and the playhead and last-start
  lines; under the hover cell.

### Session file (from milestone 13)

The beats and the notes of an audio file are stored together in a session file next to it: the
full audio file name plus `.session.json` (`song.mp3` → `song.mp3.session.json`), read when the
audio file is opened. It replaces milestone 6–12's `.beats.json` sidecar (not read any more, no
conversion: the prototype keeps no backward compatibility).

    {"beats": [{"sample": 22050, "firstBeat": "auto"}, {"sample": 44100, "firstBeat": "start", "timeSignature": "3/4"}, …],
     "notes": [{"points": [{"beat": 3, "tau": "1/2", "pre": 60, "post": 60}, …],
                "end": {"beat": 4, "tau": "0/1", "pitch": 60}}, …]}

- `beats`: in strictly ascending `sample` order (0 ≤ sample < frame count), `firstBeat` `auto`
  or `start`, `timeSignature` optional (`n/d`, n ≥ 1, d one of 1, 2, 4 … 128).
- `notes`: `beat` is an index into `beats`; `tau` the exact fraction as "n/d" (written reduced,
  "0/1" for 0); `pre`, `post`, `pitch` MIDI numbers 0 … 127. Points strictly increasing, the end
  after the last point, τ > 0 only before another beat.
- Unknown keys are ignored. Anything else is invalid (not JSON, not an object with `beats` and
  `notes` arrays, a missing or wrong value, beats out of order, a wrong reference): an alert
  ("Could not read the session") names the file and the problem; the audio file opens normally,
  with no beats and no notes. No session file: no beats and no notes.
- Written after every change of the beats or the notes (on release for a drag), replacing the
  file atomically. If writing fails, an alert ("Could not save the session") names the file and
  the reason; the beats and notes stay in memory.

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
pane (from milestone 10: its columns instead, see below). From milestone 3 on, also: `--view=<start>,<end>` and `--select=<start>,<end>` (seconds;
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
⌘-scroll gesture. From milestone 11 on, also: each waveform pane's dump has `editorLines`, the
drawn bar, beat and grid lines (kind, time, axis position), and the dump adds the grid settings
(checkbox, kind, each kind's value, the current n); commands `gridlines on|off` and
`grid straight|triplet|tuplet [n]` set them through the control's code paths. From milestone 12 on,
also: each dumped beat has its bar number, beat in bar, signature in effect, effective signature
(bar starts) and whether it is selected; the dump adds the selected beat indices, the anchor,
the beat context menu as it would open now (title, enabled, checked, separator, section header),
the axis positions of the drawn selected beats, the open beat dialog, the time signature
dialog's fields (change, inherited, numerator, denominator, OK enabled) and the subdivide
dialog's (text, maximum, OK enabled), and the strip's beat marks carry their samples; commands
`beatsel <i,j,…>|none` (selection by index, the last one the anchor), `beatmenu <title>` (runs a
menu item's action), `tsdialog ok|cancel|mode change|continue|numerator <n>|denominator <d>`
and `subdivide <n>|ok|cancel` (through the dialogs' code paths). Milestone 7's `tsdialog
<n>/<d>|dontset` is gone. From milestone 13 on, also: the grid settings in the dump have
`panelOpen` and `harmonics` (no checkbox); the main pane's dump has `hoverCell` (start and end
time and beat position, note, rectangle, the harmonic copies' rectangles, or null), `dashPhase`
and `dashesMoving`, and `notes` (per note its points and end as stored, by beat index and τ,
its start and end time and sample, the first pitch, the beat indices it uses and its drawn
rectangle); the spectrogram controls report their frames (`harmonicsPicker`, `gridControl`,
`modePicker`, `windowSlider`, `windowReadout`, `progress`); commands `gridpanel open|close`
(replaces `gridlines`), `harmonics <n>`, `notes clear`, and `beatat <seconds>` (B with the
pointer exactly at that time over the main pane). From milestone 10 on, also: each waveform pane's dump has `columns` instead of
`points`: per drawn column its index j, the min, max and rms (before the amplitude zoom), and the
drawn extents of the min/max bar and of the RMS span (whose endpoints are the marks) across the
time axis (pane coordinates, after the zoom
and the clipping); and the time the last column computation took. From milestone 2 on, `--snapshot` captures the real window, including the toolbar, by running
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
  (wheel turned up / away, or two fingers moved down with natural scrolling) zooms in (from
  milestone 10, for the amplitude zoom in horizontal mode, a negative one: wheel turned down /
  towards, or two fingers moved up). A pinch
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
- Beat cursor: open hand, closed hand while dragging (milestone 12: resize arrows over a beat,
  open / closed hand with a selection).
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
- (Milestone 10) Waveform columns: L columns per pane (one per point, time slice j…j+1), not the
  earlier L+1 polyline positions, so each bar fills one point column exactly. The RMS uses the
  same value set as the min/max (the edge values included), so it is defined at any zoom.
- The RMS hiding threshold (1 ms per column) is a constant, `WaveformNSView.rmsHideSecondsPerColumn`.
- Column computation: a min/max/sum-of-squares summary of the mono mix in blocks (computed once at
  load with vDSP, next to the mono mix) gives whole blocks inside a slice; the partial blocks
  at the slice ends are read from the samples, so the result equals the direct computation.
  The columns are cached per pane by (file, visible range, length), so a redraw for the playhead
  alone doesn't recompute them.
- The earlier milestones' verification scripts that read the `points` dump (milestones 2–3) no
  longer match; they are not re-run (see CLAUDE.md).
- (Milestone 11) The Grid lines checkbox sits in the toolbar next to the Grid button (not in the
  panel), so the grid can be switched without opening it.
- Grid lines are computed per draw for the visible range only (bars overlapping it); exact
  fractions decide whether a grid line falls on a beat.
- The crowding threshold (6 points) and the line widths and dash pattern are constants in
  `GridConstants`.
- (Milestone 12) Beat data: `firstBeat` is `auto` / `start` (an enum `Beat.Bar`); everything else
  about bars is computed on demand (`barLayout`) and kept next to the beats in the app state.
  Beats carry an in-memory id (not saved) so the selection survives moves.
- A time signature change makes its beat a bar start without changing `firstBeat`, so removing
  the signature ("Continue") gives the beat back its earlier `auto` / `start` choice.
- Context menu items are chosen in the verification with the keyboard (Down, Return): pressing
  them through Accessibility reports success but doesn't run them. The menu sends its action
  after its fade-out, so the script waits 0.5 s before the dump. The input driver gained
  `rclick x y`.
- The cursor dump knows `resizeLeftRight` / `resizeUpDown`.
- (Milestone 13) "Single pixel" lines are 1 point (2 physical pixels on Retina), as elsewhere.
- Hover cell and grid lines share one implementation of the grid (`gridSegments`,
  `gridCellSpan`), with exact fractions; the hover cell is computed from the pointer per draw.
- The moving dashes are a 1/16 s timer on the main pane that runs only while the last draw used
  them; the dash length (4), step (0.5) and interval are constants in `GridConstants`.
- The main pane clips its drawing to its bounds (macOS 14 views don't by default): harmonic
  copies above the pane spilled onto the scrollbar.
- Note areas round their edges to whole points (the hover cell centres its lines on them), so
  neighbouring notes never overlap.
- Placing the same note twice adds nothing; overlapping different notes are allowed.
- Note trajectories carry an in-memory id; grid locations refer to beats by id in memory and by
  index in the file (hence the beats' strict order in the file).
- Beats a note uses: from ⌊start⌋ to ⌈end⌉ in beat positions. Deleting is all-or-nothing (the
  user's choice); insertion is refused strictly between those beats.
- Pitch transitions only exist where pre ≠ post, so a plain note doesn't start an eighth beat
  early.
- The session file's `tau` is a string "n/d" so it stays exact; pitches are written as JSON
  numbers.
- Verification: invalid session files are checked without input events (the error alert keeps
  the window from becoming key); `beatat` places a beat at an exact time, because a mouse
  position at exactly the minimum distance could beep for the distance rule instead.
