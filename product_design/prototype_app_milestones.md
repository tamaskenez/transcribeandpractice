# Prototype Application Milestones

## 1. Skeleton + Load

An empty GUI application, except File -> Open to load an audio file.
When loaded, some basic information is displayed about the file.

Status: `verified`

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

## 2. Subwindows, wave form display

Navigator + main + toolbar + transport windows, zoom, pan and H/V orientations

