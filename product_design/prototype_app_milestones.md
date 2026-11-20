# Prototype Application Milestones

## 1. Skeleton + Load

An empty GUI application, except File -> Open to load an audio file.
When loaded, some basic information is displayed about the file.

Status: `done`

Acceptance criteria:

Test audio is generated for the purpose (sine tones with known frequency, amplitude and duration):
mono and stereo; 44.1 and 48 kHz; WAV (16- and 24-bit), AIFF, CAF, MP3, AAC/M4A, ALAC, FLAC. Plus
invalid files: a text file renamed to `.wav`, and a damaged M4A (cut inside its index).
(Originally a truncated WAV; changed during implementation because AVFoundation loads the part of a
truncated WAV that is there, see Decisions in prototype_app_spec.md.)

1. A single command-line script builds the `.app` bundle without errors.
   Verified by: running the script (exit code 0, the bundle exists).
2. On launch, the app shows one window with the title "Transcribe and Practice" and the hint
   "Open an audio file (⌘O)".
   Verified by: snapshot and state dump.
3. The main menu has File → Open… with the shortcut ⌘O.
   Verified by: menu structure in the state dump. That the open dialog appears and accepts only
   audio files is checked by hand during review, because driving the real menu and dialog would
   need Accessibility permission.
4. Each valid test file loads, and the info display shows its file name, duration, sample rate,
   channel count, frame count, and per-channel peak and RMS levels.
   Verified by: state dump compared to the generator's expected values. Sample rate and channel
   count must match exactly. Frame count and duration must match exactly for lossless formats, and
   within 0.1 s for lossy ones (encoder padding). Peak and RMS must be within 0.1 dB for lossless
   formats and 1 dB for lossy ones. A snapshot is also checked for one file.
5. The decoded audio is held in memory as 32-bit float, with all channels at the file's sample rate.
   Verified by: buffer format reported in the state dump (sample type, channels, sample rate,
   frames) for each valid test file.
6. Opening a second file replaces the first; the window title shows the new file's name.
   Verified by: opening two files in sequence and checking the state dump.
7. Opening an invalid file shows an alert with the reason, and the previously loaded file stays
   loaded and displayed.
   Verified by: opening a valid file and then each invalid file, and checking the alert text and
   loaded file in the state dump.

Verification results (`python3 prototype/verify/verify_m1.py`): 28/28 checks passed.

1. Build script: exit code 0, bundle created.
2. Empty launch: one window, title "Transcribe and Practice", hint shown (snapshot checked).
3. File → Open… with ⌘O present. The open dialog itself still needs a manual check.
4. All 11 valid files (WAV 16/24-bit, AIFF, CAF float, ALAC, FLAC ×2, AAC ×2, MP3 ×2; mono and
   stereo; 44.1 and 48 kHz) load with correct values. Lossless: exact frame counts, levels
   within 0.1 dB. Lossy: within the tolerances. Snapshot checked for one file.
5. All 11 decoded buffers: float32, non-interleaved, all channels, native sample rate.
6. Opening a second file replaces the first; the title shows its name.
7. `not_audio.wav` and `damaged.m4a` show an alert; the previous file stays loaded.

## 2. Subwindows, waveform display

- Split main window into subwindows (panes): toolbar and transport panes on the top and bottom
- The middle section has 2 modes: horizontal and vertical orientation (of time axis)
- In both modes, the middle section is split into two:
  - a navigation window (which is a waveform display)
  - main analysis window
- In horizontal time mode the middle section is split into a top, navigation pane and a bottom main pane
- In vertical time mode it's split into a left, navigation pane, and a right, main pane
- For now both in the navigation and main window we display a mono waveform mix

Status: `done`

Acceptance criteria:

Test audio, in addition to the milestone 1 set: a mono 1 Hz sine (amplitude 0.8, 4 s), and a
stereo file whose left channel is the same sine and whose right channel is a constant 0.4, so the
mono mix is 0.4·sin + 0.2. At this frequency the point-sampled waveform is a smooth, recognizable
curve.

Waveform reference: a Python script computes the expected polyline from the generated signal,
using the same rule as the app (column i of n maps to sample position i·(frames−1)/(n−1), linear
interpolation, mono mix = channel average, ±1.0 = pane edges).

1. Both builds (`build.sh` and CMake) still build the app without errors.
   Verified by: running both (exit code 0, bundle exists).
2. Horizontal layout: native toolbar with the orientation toggle, navigator pane above the main
   pane with a divider between them, transport pane at the bottom. The navigator takes about 20%
   (±2%) of the middle section at launch.
   Verified by: pane frames and toolbar items in the state dump (order, no overlap, ratio), and a
   screenshot of the real window, inspected visually.
3. Vertical layout: navigator on the left, main pane on the right, same 20% default.
   Verified by: as criterion 2, with `--orientation=vertical`.
4. The View menu has Horizontal Time (⌘1) and Vertical Time (⌘2), and the toolbar toggle reflects
   the current orientation.
   Verified by: menu structure and toolbar state in the state dump. Clicking the toggle, using the
   menu items and dragging the divider are checked by hand during review (driving real input would
   need Accessibility permission).
5. The orientation is remembered across launches.
   Verified by: launching with `--orientation=vertical`, quitting, relaunching without the option
   and checking the dump; then the same back to horizontal.
6. Both panes show the mono mix of the whole file as specified, in both orientations.
   Verified by: polyline points from the state dump compared to the Python reference for both test
   files, both panes and both orientations (within 0.5 px).
7. The waveforms look right on screen.
   Verified by: screenshots of both test files in both orientations, inspected visually (a sine
   running to the right / downwards, the stereo one offset by +0.2).
8. With no file loaded, the panes are present and empty, and the main pane shows the hint.
   Verified by: state dump (no waveform points, hint present) and a screenshot.
9. The transport pane shows the one-line file summary; opening a second file replaces the waveform
   and the summary.
   Verified by: state dump after opening two files in sequence.
10. Milestone 1 behavior still holds (loading all formats, file info values, error alerts).
    Verified by: `verify_m1.py`, adapted to the moved info display.

Prerequisite: Screen Recording permission for the terminal running the verification (for
`screencapture -l`).

Verification results (`python3 prototype/verify/verify_m2.py`): 21/21 checks passed; screenshots in
`prototype/verify/out/m2/` inspected.

1. `build.sh` and the CMake (Ninja) build both exit 0 and create the bundle.
2. Horizontal layout correct for both files: panes stacked, full width, navigator 20%, toolbar
   toggle present and selected. Screenshots show toolbar, navigator, main pane, transport strip.
3. Vertical layout correct for both files, same checks. Screenshots show navigator left, main
   right.
4. View menu: Horizontal Time ⌘1, Vertical Time ⌘2. Clicking the toggle, the menu items and
   dragging the divider still need a manual check.
5. Default horizontal; vertical and horizontal each remembered across a relaunch.
6. Navigator and main polylines match the reference for both files in both orientations (8
   comparisons, within 0.5 px).
7. Screenshots: a 4-period sine running right / downwards; the stereo file offset by +0.2;
   positive amplitude up (horizontal) and right (vertical).
8. No file: both panes present and empty, hint in the main pane.
9. After opening two files: summary "wave_stereo.wav · 0:04.000 (4.000 s) · 44.100 Hz ·
   2 (stereo)" and the stereo waveform.
10. `verify_m1.py`: 28/28 passed.

## 3. Basic navigation

- Zoom, pan, selection

Status: `done`

Acceptance criteria:

Test audio: the milestone 2 files (mono and stereo 1 Hz sines, 4 s). Input handling is verified
with synthetic events: a driver script posts real mouse, scroll and (if possible) magnify events
to the window with Quartz `CGEventPost`, then asks the running app (`--commands`) for a state dump
or screenshot. This needs Accessibility permission for the terminal. Positions are computed from
the pane frames in the dump. Tolerances: times within the duration of 1 point at the current
scale; polylines within 0.5 px. Each input criterion is checked in both orientations.

1. `build.sh` and the CMake build succeed; `verify_m1.py` and `verify_m2.py` still pass. (CLI)
2. Toolbar contains Zoom Out Full, Zoom to Selection, the selection indicator and the orientation
   toggle. After load: whole file shown, no selection, indicator `–`, both zoom buttons disabled.
   (dump)
3. `--view=1.0,2.0`: navigator and main polylines match the reference for that range (each point
   i of a pane with time-axis length L at time 1.0 + i/L s, interpolated). Scrollbar knob at
   25% with proportion 25%; Zoom Out Full enabled. Screenshot shows a quarter period of the sine
   in both panes and the scrollbar along the navigator's time axis (bottom / right edge). (dump +
   screenshot)
4. Limits via hooks: `--view=1.0,1.0002` gives a 100 ms range centered at 1.0001; `--view=-1,10`
   gives −0.05–4.05 (whole file plus margins); `--view=3.5,4.5` gives 3.05–4.05;
   `--view=-0.5,0.5` gives −0.05–0.95, with no waveform points before the file start. (dump +
   screenshot)
5. Plain drag in the main pane from 25% to 75% of the time axis selects 1.0–3.0 s (full view);
   reverse drag gives the same; a drag in the navigator selects likewise; a drag that leaves the
   pane is limited to the visible range. Indicator shows `0:01.000 – 0:03.000 (0:02.000)`, Zoom to
   Selection enabled. Screenshot shows the band in both panes. (synthetic events + dump +
   screenshot)
6. Shift-click at 90% with selection 1.0–3.0 gives 1.0–3.6; shift-click at 10% then gives
   0.4–3.6; shift-drag with no selection acts as a plain drag. (synthetic events + dump)
7. A click without drag clears the selection; Escape clears it. (synthetic events + dump)
8. Scrolling along the time axis while zoomed to 1.0–2.0 pans by the scrolled distance (pixel
   scroll events); it stops 50 ms beyond the file's ends. Horizontal mode: both axes pan; vertical mode:
   only the vertical axis. (synthetic events + dump)
9. ⌘ + scroll along the time axis zooms time in/out around the pointer: the time under the
   pointer stays put; zooming stops at 100 ms and at the whole file plus margins; the amplitude
   zoom doesn't change. (synthetic events + dump)
10. Pinch zooms around the pointer. (synthetic magnify events if macOS accepts them; otherwise
    manual check)
11. Option-drag and middle-button drag pan: the time under the press point ends up under the
    release point; panning stops 50 ms beyond the file's ends. (synthetic events + dump)
12. Dragging the scrollbar knob pans proportionally; clicking the track pans. (synthetic events +
    dump)
13. Zoom to Selection (with selection 1.0–3.0) shows 1.0–3.0; then Zoom Out Full shows the whole
    file plus margins. Buttons pressed via the Accessibility API. (dump)
14. Resizing the window, dragging the divider and switching orientation keep the visible range and
    the selection. (synthetic events / hooks + dump) This also covers the divider drag left to a
    manual check in milestone 2.
15. Opening a second file while zoomed and with a selection shows the whole new file (plus
    margins) with no selection. (hooks + dump)
16. (review) ⌘ + scroll across the time axis zooms amplitude: 100 points = +8.7 dB, the time view
    doesn't change, limited to 0–60 dB. At +20 dB both polylines match the reference ×10
    (screenshot). Zoom Out Full and opening a file reset it to 0 dB. (synthetic events + dump +
    screenshot)
17. (review) Cursor, after moving the pointer over the main pane with selection 1–3 s: the
    resize arrow along the time axis on both edges and 3 points from an edge, an open hand
    inside, the arrow outside. (synthetic events + dump of the app's current cursor)
18. (review) Dragging the end edge 75%→90% gives 1–3.6; the start edge 25%→10% then gives
    0.4–3.6; dragging an edge past the other flips the selection. Dragging inside moves it
    (1–3 → 1.4–3.4), stops at the file end, works in the navigator too; a click inside still
    clears it. (synthetic events + dump)

Verification results (`python3 verify/verify_m3.py`, 37/37 checks passed):

1. `verify_m2.py` (including `build.sh`, the CMake build and `verify_m1.py`) and `verify_m1.py`
   pass.
2. Toolbar items: Zoom Out Full, Zoom to Selection, the selection indicator, Time Orientation.
   After load: 0–4 s, no selection, `–`, both buttons disabled (dump and AXEnabled).
3. `--view=1,2`: polylines within 0.5 px in both panes, both orientations. Scrollbar legacy style,
   at the navigator's bottom / right edge, proportion 0.25, knob at 25%. Screenshots
   (`c3_*.png`) show a quarter period in both panes.
4. Limits: 0.9996–1.0006, 0–4, 3–4.
5–12. Passed in both orientations with synthetic events, including pinch (no manual check
   needed). Screenshots `in_*_selection.png` show the band in both panes.
13. Buttons pressed via the Accessibility API: 1–3 s, then 0–4 s; Zoom Out Full disabled again.
14. Resize to 800×600, divider drag (navigator fraction 0.2 → ~0.3) and orientation switch keep
    1–2 s and selection 1.2–1.5. This also covers the divider drag left to a manual check in
    milestone 2.
15. Opening `wave_stereo.wav` while zoomed with a selection shows 0–4 s, no selection.

Not checked automatically: clicking the orientation toggle and the View menu items (unchanged
since milestone 2), and how gestures feel on a real trackpad and mouse (zoom and scroll rates).

Review changes (2026-11-17): maximum zoom 100 ms instead of 1 ms; the visible range may extend
50 ms (half the maximum zoom) beyond both ends of the file, and fully zoomed out shows −50 ms …
end + 50 ms. Criteria 2–4, 8, 9, 11–13, 15 adjusted accordingly. Re-verified: `verify_m3.py`
40/40 passed (new: the margin check in criterion 3/4, with screenshots `c3b_*.png`).

Review changes 2 (2026-11-17): amplitude zoom with ⌘ + scroll across the time axis (time zoom
only along it; pinch stays time zoom); selection edges and the whole selection can be dragged,
with matching cursors; files longer than 2³⁰ − 1 frames get a clear error (see Loading audio
files). Criteria 9 adjusted, 16–18 added. Margins: already drawn with only the zero axis line
(criterion 4); see the encoder-padding note in Decisions. Re-verified: `verify_m3.py` 54/54
passed.

## 4. Playback

- We maintain a playhead, which can be set by the user but also advanced by the actual playback:
  each buffer sent to the audio output sets the playhead to the start of the last buffer. Ideally
  the buffer size is around 30-50 ms. If the display frequency is available, set the buffer size
  to the multiply of the display frequency so it falls in the said range.
- We maintain also last playback start position and loop-enabled flag
- The user actions that affect playback:
  - starting a selection or clearing it stops playback and puts the playhead at the beginning of the
    selection or where the user clicked to clear the selection
  - the "play-or-stop" action starts playing where the playhead is, or if it's already playing,
    stops playback
  - the "rewind-and-play" action sets the playhead to the start of selection (or the last clear-selection
    location) and starts playing
  - the "play-again" action starts playing from where the last playback started
  - if there's no selection, the playback automatically stops at the end of file and playhead
    rewinds to start of file
  - if there's a selection but loop is not enabled, the playback stops at selection end and rewinds
    to selection begin
  - if there's a selection and loop is enabled, the playback continues where selection begin
  - the user actions are bound to these keys:
    SPACE: "play-or-stop"
    LEFT-ARROW: "rewind-and-play"
    RIGHT-ARROW: "play-again"
  - the transport pane has 3 buttons corresponding to these actions, a loop-enable button and also
    displays the position of the playhead

Status: `done`

Acceptance criteria:

Test audio: a 10 s stereo 44.1 kHz float WAV of seeded white noise (left and right different) at
−12 dBFS, so any rendered sample range can be located exactly; plus the milestone 2 sine for
screenshots. Output content is checked from the `record` hook (what the source node renders);
timing from state dumps taken every ~100 ms while playing. Sound is audible during the tests.
Key presses, clicks and drags use the milestone 3 synthetic-event driver; buttons are pressed via
Accessibility. Each check runs in horizontal mode; the mouse and display checks also in vertical.

1. Builds; `verify_m1.py`, `verify_m2.py`, `verify_m3.py` still pass. (CLI)
2. Transport pane shows rewind-and-play, play-or-stop, play-again, loop and the playhead
   position `0:00.000` after load; toolbar shows the follow button; loop and follow off. (dump +
   AX + screenshot)
3. I/O buffer: duration within 30–50 ms and a multiple of the display refresh period (within one
   sample); one playhead update per buffer. (dump)
4. Play-or-stop from playhead 1.0 s: the rendered audio equals the file's samples from 1.0 s on,
   both channels (sample-exact); the playhead advances at real-time rate (slope 1 ± 2%) and lags
   the rendered position by the reported latency (± one buffer). Space stops it; the playhead
   stays (within one buffer + latency of the stop time). (record + dumps + synthetic keys)
5. No selection: playback from 9.5 s stops by itself at the file end; playhead back at 0;
   rendered audio ends with the last sample. (record + dumps)
6. Selection 2–3 s, loop off, playing from 2.0: stops at 3.0 s, playhead at 3.0 (review change;
   was: back at 2.0); rendered audio = samples 2.0–3.0 exactly. (record + dumps)
7. Selection 2–3 s, loop on: after 2.5 s of playback the rendered audio is 2.0–3.0, 2.0–3.0,
   2.0–2.5 with no gap or repeated sample at the joins. (record)
8. Selection 2–3 s, loop off: playback that doesn't start at the selection start continues
   through the selection end to the file end: (a) start at 2.0, stop at ~2.5, continue (Space);
   (b) start at 4.0 (outside). Playback started at 2.0 still stops at the selection end after the
   selection was moved during playback to 2.5–3.5 (stops at 3.5, playhead at 3.5). Moving the
   selection end before the play position during playback (started at 2.0, at ~2.6 drag the end
   edge to 2.3) doesn't stop it: it plays to the file end. Loop on: playback started at 4.0
   ignores the selection; moving the end before the play position during a loop doesn't loop
   back. (synthetic events + dumps + record)
9. Rewind-and-play (Left Arrow and button): from a running playback, restarts at the selection
   start; with no selection, at the last clicked position; after opening a file, at 0. Play-again
   (Right Arrow and button): restarts at the last playback start. (synthetic keys, AX, record +
   dumps)
10. Mouse: during playback, a click stops it and puts the playhead and rewind point at the
    clicked time; a new selection drag stops it with the playhead at the selection start; Escape
    stops it with the playhead at the former selection start; an edge drag and a move during a
    looping playback don't stop it, and the loop uses the new bounds (rendered audio). (synthetic
    events + record + dumps)
11. Display: the playhead line in both panes at the playhead's position and a mark on the
    scrollbar track, both orientations. (screenshots + dump of the drawn positions)
12. Follow on, view 1.0–2.0 s, playing from 1.0: within 2 s of the playhead reaching the center
    the view is ≥ 4.9 s long and the playhead within 10% of the center; with follow off the view doesn't move; a manual scroll
    during playback turns follow off. (synthetic events + dumps)
13. Loop and follow flags remembered across a relaunch. Opening a file stops playback and
    resets the playhead to 0. (hooks + dumps)

Verification results (`python3 verify/verify_m4.py`, all criteria passed):

1. `verify_m3.py` (with `verify_m2.py`, `verify_m1.py`, `build.sh`, CMake): its toolbar check
   first failed because of the new Follow Playhead button; after allowing it, 54/54.
   `verify_m1.py` 28/28.
2. Transport buttons and the follow button found and enabled via Accessibility; after load
   playhead 0, loop and follow off.
3. I/O buffer 1440 frames at 48 kHz = 30.0 ms, 3 × the 100 Hz refresh period.
4. Rendered audio from 1.0 s sample-exact; playhead slope 0.996; lag = latency (30.6 ms) + less
   than one buffer; one playhead update per callback; Space stops and keeps the playhead.
5–7. File end, selection end (loop off) and loop: rendered audio sample-exact, rewinds as
   specified.
8. All five cases pass (stop + continue, start outside, moved selection, end dragged behind the
   playhead with loop off and on). The drag case needed the rule that the end is ignored while
   being dragged (see Playback in the spec).
9. Rewind-and-play and play-again, keys and buttons.
10–11. Both orientations: click / new selection / Escape stop playback as specified; edge drag and
   move during a loop keep playing with the new bounds (rendered audio); playhead line and
   scrollbar mark at the expected positions (screenshots `mouse_*_playhead.png`).
12. Follow off: view unchanged; on: 4.97 s view, playhead 8.8% from the center after 2 s
    (screenshot `c12_follow.png`); a manual scroll during playback turns it off.
13. Loop and follow remembered; opening a file stops playback, playhead 0.

Not checked automatically: how playback sounds on other output devices (Bluetooth latency) and
on displays with other refresh rates.

Review changes (after the first verification):

- Follow engages only when the playhead reaches the view center, and not at all while the
  expected end of the playback is in the view.
- After an automatic stop at the selection end the playhead stays there, so play-or-stop
  continues from the selection end; rewind-and-play goes back to the selection start.
- The last playback start is shown as a line (desaturated playhead red, under the playhead).
- New action set-last-playback-started (Down Arrow).
- The playhead (when stopped), the last start and the selection edges can be hovered and
  dragged; lines at the same position move together.
- Every direct change of the playhead by the user also sets the last playback start.
- Follow fix found while verifying: the view now moves along with the playhead (it used to stay
  about 0.5 s behind it, the 8.8% offset seen in criterion 12).

Additional acceptance criteria (`python3 verify/verify_m4_review.py`; mouse checks in both
orientations):

14. Follow on, view 1–6 s, playing from 1.0: while the playhead is before the center the view
    doesn't move; after it passed the center follow is engaged and the playhead is within 2% of
    the center. A playhead outside the view (view 5–6) engages it at once. (synthetic keys + dumps)
15. Follow on: no view movement and no engagement when the expected end is in the view —
    selection 2–3 in view 1.5–3.5 (loop off and loop on), file end in view 7–10 playing from 8.6.
    Looping with the end visible but the loop start not (view 2.4–3.4): follow engages. (dumps)
16. After the stop at the selection end (2–3): playhead 3.0; Space plays from 3.0 (rendered
    audio); Right Arrow plays from 3.0 again; Left Arrow from 2.0. (record + dumps)
17. The last-start line in both panes at its position and a mark on the scrollbar, the playhead
    line elsewhere. (dump of the drawn positions + screenshots)
18. Down Arrow during playback sets the last start to the playhead; Right Arrow then plays from
    there. (synthetic keys + dumps)
19. Dragging lines: stopped, hovering the playhead shows the resize cursor and dragging it moves
    the playhead, the last start and the rewind point (no selection made); the selection start
    with the playhead and last start on it drags all three; during playback the last start drags
    alone (playback goes on), and with the selection start on it both drag together. (synthetic
    events + dumps)
20. A click, a new selection and Escape put the last start at the new playhead. (synthetic events
    + dumps)

Review verification results:

- `verify_m4_review.py`: 23/23. Follow waits before the center and then keeps the playhead at
  the center (+0.0%); no engagement with the end in view; continue from the selection end
  (rendered audio from 3.0); Down Arrow set the last start to 2.109 during playback; all line
  drags in both orientations; last-start line and mark at the expected positions (screenshots
  `r_horizontal_laststart.png`, `r_vertical_laststart.png`).
- `verify_m4.py` with the updated criteria 6, 8 and 12: 27/28; criterion 12 now +0.0% from the
  center (was 8.8%). The failure was criterion 1: `verify_m3.py` criterion 5 started a navigator
  drag at 25% where Escape had left the (now draggable) playhead, so it moved the playhead
  instead of selecting. The test now moves the playhead away first; `verify_m3.py` then 54/54.

Not checked automatically: that the playhead can't be grabbed during playback (a moving line
can't be hit reliably with synthetic events; covered by the hover code path, which skips the
playhead while playing).

## 5. Time markers

- We need time markers in the navigation pane, for horizontal time in the top line of the pane, for
vertical top in the left column.
- The time markers consists if ticks and numbers (right of the ticks or below the ticks)
- The numbers should be in "min:sec.999" format
- If the user clicks or drags in the time markers area, it behaves differently: it does not change the
  selection, only the playhead or last-playback-started position.

Status: `done`

Review changes: the selection band is no longer painted over the strip; labels less dense (at
least 30 pt between labels instead of 8).

Acceptance criteria:

Test audio: the milestone 4 10 s noise WAV and the milestone 2 sine, plus a generated 12-minute
silent mono WAV for long-file labels. Mouse input uses the synthetic-event driver; checks run in
both orientations unless noted.

1. Builds; `verify_m1.py` … `verify_m4.py` and `verify_m4_review.py` still pass (scripts that
   depend on the navigator's waveform geometry may be adjusted to the strip). (CLI)
2. Layout: horizontal: the strip spans the navigator's top, about 18 pt tall, with the waveform
   below it and the scrollbar unchanged at the bottom; vertical: the strip is the navigator's left
   column, at least as wide as the widest label, with the waveform right of it. The main pane has
   no strip. No file loaded: no ticks. (dump of frames + screenshots)
3. Ticks, for the views 0–10 s (whole file), 1–2 s, 1–1.1 s (maximum zoom) and the whole 12-minute
   file, at two window sizes: major ticks at the multiples of the expected step (the smallest one
   in the list whose labels keep ≥ 30 pt apart (review change; was 8), computed from the dumped label frames), each tick
   within 0.5 pt of its time's position in the waveform's mapping; minor ticks evenly between, with
   the specified count; labels in the specified format (e.g. `0:05`, `0:01.5`, `0:01.05`, `10:00`);
   no label overlaps another or leaves the strip; no ticks outside 0 … duration. (dump +
   screenshots)
4. The ticks follow zoom, pan, window resize, divider drag, orientation switch and follow during
   playback (dump after each matches the visible range as in 3). (commands, synthetic events, dump)
5. Playhead and last-start lines are drawn through the strip; the selection band is not (review
   change; was drawn). (screenshot,
   pixel check at the line positions inside the strip)
6. Stopped, with a selection 2–3 s: a click in the strip at 5.0 puts the playhead, last start and
   clear point at 5.0; a drag 5.0 → 6.0 → 4.0 ends with them at 4.0 (playhead at ~6.0 in a dump
   mid-drag); the selection stays 2–3; playback doesn't start. Without a selection, Left Arrow
   then plays from the clicked point. A drag beyond the view end stops at the view end. (synthetic
   events + dumps)
7. Playing from 1.0: a press in the strip at 6.0 jumps the playback there: the rendered audio
   continues with the file's samples from 6.0 (record), playing stays on, last start 6.0,
   selection unchanged; moving the pointer to 7.0 before release changes nothing. With a
   selection 2–3 s and loop on, a press at 2.2 during playback from 5.0 then loops in 2–3
   (2.2 rather than 2.0: a press at 2.0 can land a pixel before the selection, which is outside it).
   (synthetic events + record + dumps)
8. Last-start line in the strip: hovering it shows the resize cursor; stopped (away from the
   playhead) and playing, dragging it moves only the last start, playback unaffected; a press on
   a selection edge's position in the strip acts as a plain strip press (moves the playhead), the
   selection is unchanged. (synthetic events + dumps)

Verification results after the review changes (`python3 verify/verify_m5.py`, run from
`prototype/`; screenshots in `verify/out/m5/`): 39/39 checks passed.

1. `verify_m4.py` (which runs `verify_m3.py` → m2, m1, `build.sh`, the CMake build) and
   `verify_m4_review.py` pass unchanged.
2. Horizontal: strip 18 pt at the navigator's top, waveform below, scrollbar at the bottom.
   Vertical: 53 pt left column. Not in the main pane; no ticks without a file.
3. Both orientations, 1000×700 and 700×450: whole file: 1 s step (`0:00`, `0:01` …, 5 minor
   parts; 2 s in the shorter vertical strip); 1–2 s: 0.1 s (0.2 s); 1–1.1 s: 0.01 s or 0.02 s;
   the 12-minute file: 1 min step up to `12:00`. Steps minimal, ticks within 0.5 pt, labels
   ≥ 30 pt apart and inside the strip.
4. Ticks match the view after zoom, pan, resize, divider drag, orientation switch and follow.
5. Pixels inside the strip: playhead red, last start desaturated red; inside the selection the
   strip stays untinted grey like outside it.
6. Click / drag (with a mid-drag dump) / drag past the view end, selection kept, no playback;
   ← afterwards plays from the clicked point.
7. A press at 6.0 during playback: the rendered audio continues sample-exactly from 6.0; dragging
   on changes nothing. Loop case loops in 2–3.
8. Last-start line: resize cursor; dragged alone stopped and during playback; presses at the
   selection edges in the strip move the playhead, the selection stays.

Not checked automatically: Option/middle-drag pan, scrolling and pinch inside the strip itself
(the same code as the navigator, which `verify_m3.py` covers).

## 6. Beat markers

- We need to introduce a new state, a list of beat markers. They contain:
  - their sample position
  - a "source" field: Placed | computed. Placed means it is placed by the user, won't be updated by the app. "Computed" means it was extrapolated by the app, from other, "placed" beats. All computed beats will be recalculated when the placed beats change (next milestone)
  - an optional "time_signature" field (4/4, 3/4, etc... ). Each beat either introduces a new time signature or inherits the previous.
  - a "first_beat" field: no | placed | computed. This field means the beat starts a new bar (it's downbeat). It can be set by the user (placed) or computed from the previous beats and time signature (next milestone)
- The presentation of the beats:
  - beats are displayed similarly to time. small ticks for beats which have "first_beat: no" and big ticks + number for the rest of the beats.
  - if the beat is a computed beat, instead of the small tick draw a dot
  - if the beat has "first_beat: computed" use a dotted line for the big tick
  - add a toggle to the the toolbar which toggles between displaying beats (default) or time only.
  - if there are no beats at all, the toggle is disabled and display time
- add a new indicator line in the time/beat marker area, a vertical line for horizontal time or horizontal line for vertical line. It should follow the mouse pointer's time coordinate.

Status: `done`

Acceptance criteria:

Test audio: the milestone 4 10 s noise WAV (44.1 kHz) with generated sidecar files. The main
test beat list: two pickup beats (placed, then computed), then bars of 4 beats at 120 BPM with a
mix of placed and computed beats and `firstBeat` placed / computed / no, and one time signature
change. Mouse input uses the synthetic-event driver; checks run in both orientations unless
noted.

1. Builds; `verify_m1.py` … `verify_m5.py` and `verify_m4_review.py` still pass (their files
   have no sidecar, so the strip shows time). (CLI)
2. Sidecar loading: a valid, unsorted file is loaded sorted, with every field as written; no
   sidecar → no beats; an empty array → no beats, no alert; each invalid case (not JSON, not an
   array, a missing field, an unknown `source` / `firstBeat` value, a malformed time signature,
   a negative sample, a sample ≥ the frame count, a duplicate sample) → an alert naming the
   sidecar file and the problem, the audio loaded, no beats; opening a second audio file
   replaces the beats. (CLI dump)
3. Beats mode, for the views 0–10 s, 2–4 s and 0–1 s at two window sizes: one mark per beat in
   the view, each within 0.5 pt of its time's position in the waveform's mapping; kinds as
   specified (big tick, dotted big tick for `firstBeat: computed`, small tick, dot); bar numbers
   1, 2, 3 … counting the downbeats, none on the pickup; no time ticks. (dump + screenshots)
4. Crowding: with a dense test list (240 BPM over the whole file) and the whole file in view:
   the bar number step k is the smallest power of two keeping ≥ 30 pt between labels (computed
   from the dumped label frames), the un-numbered downbeats are drawn as small marks, and small
   marks follow the 4 pt rule; zooming in brings back every bar number and all small marks.
   (dump)
5. Toggle: beats mode by default; the toolbar button and View → Show Beats (⌘B) both switch to
   time mode (the strip then has the milestone 5 time ticks) and back; the choice survives a
   relaunch; a file without beats disables the button and the menu item and shows time, and the
   next file with beats shows beats again. The vertical strip is at least as wide as the widest
   bar number and time label. (Accessibility + dump)
6. The marks follow zoom, pan, window resize, divider drag and orientation switch (dump after
   each matches the visible range as in 3). (commands, synthetic events, dump)
7. Pointer line: with the pointer over the navigator waveform at time t, and over the strip, the
   line is at t (within 0.5 pt) in both modes; over the main pane at time t, the line is at t
   (implementation finding: the panes share one visible range, so the "main-pane time outside
   the navigator's view" case can't occur); over the scrollbar or the transport pane, no line; with the pointer held
   still, a pan (scroll) moves the line to the pointer's new time. The line is visible in a
   screenshot (pixel check). (synthetic events + dump + screenshot)
8. A click and a drag in the strip in beats mode move the playhead as in milestone 5, the
   selection unchanged. (synthetic events + dump)

Verification results (`python3 verify/verify_m6.py`, run from `prototype/`; screenshots in
`verify/out/m6/`): 51/52 checks passed in the full run; the one failure was criterion 1, from two
timing flakes in the earlier scripts (`verify_m3` criterion 18, a vertical edge flip, and
`verify_m4` criterion 7, a loop recording cut to 0.33 s), both unrelated to the strip; a rerun of
`verify_m4.py` (with m3, m2, m1 and the builds) passed 28/28. With `SKIP_EARLIER=1`: 51/51.

1. `verify_m5.py` (with m1 … m4, m4_review) passes; `verify_m3.py`'s toolbar check now allows the
   Show Beats button.
2. The valid sidecar loads sorted with all fields; no sidecar / empty array: no beats, no alert;
   10 invalid cases (incl. "not an array of objects") each give an alert naming the file
   (“Could not read beats”), the audio loads without beats; opening another file replaces the
   beats.
3. Both orientations, 1000×700 and 700×450, views 0–10, 2–4, 0–1: marks within 0.5 pt, all four
   kinds, bars 1–5, no number on the pickup, no time ticks.
4. Dense list (12 min, 240 BPM), whole file → 0–150 → 0–60 → 0–10 s: horizontal k 64, 8, 4, 1 and
   small marks none, downbeats, all, all; vertical k 64, 16, 8, 1 and none, downbeats,
   downbeats, all; each k minimal.
5. Default beats; toolbar button and ⌘B toggle (menu checkmark follows); the choice survives a
   relaunch; without beats the button (AX) and the menu item are disabled, ⌘B does nothing, the
   stored choice is kept; vertical strip 53 pt in both modes.
6. Marks match the view after zoom, pan, resize, divider drag and orientation switch.
7. Pointer line at the pointer's time over the navigator, the strip and the main pane in both
   modes; none over the scrollbar or the transport pane; follows a pan under a still pointer;
   visible in screenshots.
8. Strip click and drag in beats mode move the playhead; the selection stays.

## 7. Computed beats and bars

- we also introduce a constant "beat_note". Later, we will expose it on the UI but now it's a constant but we already use it in calculations. The value is a rational number, the note duration to which BPM refers to. Now it's fixed to 1/4.

What to do with computed beats:

Whenever the user changes (creates, deletes, modifies) a "placed" beat,
- delete all computed beats
- set all beat.bar == computed fields to no
- run this recomputation algorithm:

```
If there are less then 2 placed beats, done.
current_bpm = none
loop, examine all adjacent (placed) beat pairs (b1, b2):
    if current_bpm is not none:
        insert as many computed beats between b1 and b2 which minimizes the difference between current_bpm and the resulting bpm between b1 and b2. Minimize log(current_bpm / result_bpm)
        set current_bpm = result_bpm
    else:
        result_bpm = bpm between b1 and b2 (60 / (time(b2) - time(b1))
        if result_bpm >= 30:
            current_bpm = result_bpm
if current_bpm is not none:
    continue inserting computed beats after the last beat until end of file, at current_bpm

current_time_signature = none
beat_in_bar = 1
loop, for all beats (computed and placed)
    if beat.time_signature is not none:
        current_time_signature = beat.time_signature
    if current_time_signature is none:
        continue
    if beat.bar == placed
        beat_in_bar = 1
    elif beat_in_bar == 1
        set beat.bar = computed
    # Advance beat_in_bar
    beat_in_bar = (beat_in_bar mod time_signature / beat_note) + 1
```





## Fine-tuning (to do later)

- Don't drag playhead/last-playback-start when dragging selection edge
- Revise follow-logic
- Better last-playback-start marker color
- Don't draw the playhead and last-playback-started markers on the scrollbar if they are in the view range. Draw only those which is off screen.