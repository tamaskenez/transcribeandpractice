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

Status: `criteria proposed`

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

## 3. Basic navigation

- Zoom, pan, selection
