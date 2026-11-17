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
