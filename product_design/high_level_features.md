# High-level features

## Union of the features of five existing transcription / practice apps

This is an exhaustive list, the actually planned features might be less, see the next section.

Legend: **T** = Transcribe! (Seventh String), **A** = Anytune, **C** = Capo (SuperMegaUltraGroovy), **M** = Moises, **S** = Song Master / Song Master Pro (Aurally Sound)

### Import and library
- Import audio files (all)
- Audio CD and analog recording (T)
- Video: shown alongside the audio (T), audio extraction (A), video upload (M)
- Import from the Apple Music library (A, C); slowing down Spotify / Apple Music streams (A, Android)
- Cloud import from Dropbox, Drive, iCloud or a URL (A, M)
- Folders and playlists (A); setlists, including shared ones (M)
- Sync across devices (A, C); sharing projects, marks and loops (A, C)

### Playback and navigation
- Waveform with scroll and zoom (T, A); double waveform (A)
- Click to play from any point (T); freeze and scrub (C)
- Playhead that stays in place (C); continuous scrolling (S)
- Keyboard shortcuts (T, C); hands-free control by foot pedal, MIDI or Bluetooth (T, A, C)
- Count-in (A, C, M)

### Speed and pitch
- Tempo change without changing pitch (all); range 0.05–2× (T), 0.25–1.5× (C)
- Pitch shift and transpose (all), cent-level control (T)
- Transposing-instrument setting (T); virtual capo and alternate tunings (C)

### Isolating parts of the audio
- Karaoke (phase-cancellation) mode (T)
- EQ filter (T); parametric EQ (A)
- AI stem separation with solo, mute and remix (A, C, M, S); choice of 4- or 6-stem models (S)
- Mixing in live instrument or voice input (A)

### Analysis
- Beat and bar grid: detected (C, S), editable (C), placed by hand as markers (T)
- Tempo/BPM (C, M, S), key (C, M, S), time signature (S), tuning (S)
- Section detection (M, S)
- Chord detection (T as "guesses", C, M, S): editable (C), difficulty levels (M), bass notes when not the root (S), Roman / Nashville notation (S)
- Note and pitch detection (T, S Pro)
- Spectrum over a keyboard (T), spectrogram (C), piano roll of detected notes (T)
- Lyric transcription (M)

### Annotation and structure
- Markers and named sections (T, A, C), colored on Android (A)
- Text annotations (T); scrolling lyrics or tabs (A)
- Chord diagrams for several instruments, left-handed option (C)
- Drawing notes on the spectrogram to generate tabs automatically (C)
- Sheet-music-style song view (S Pro)
- Separate view modes, e.g. Chords, Tabbing, Structure, Practice (C)

### Practice tools
- Stored, named loops (T, A, C, M, S); loops that snap to the beat grid (C)
- Loop trainer with repeat count, tempo ramp and auto-advance (A, S)
- Metronome synced to the song (T, C, M, S); standalone metronome (S)
- Phrase and key trainers (S)
- On-screen reference keyboard (T)
- Backing tracks with a part removed (A, M)

### Export
- Processed audio (T, C, M, S)
- Stems and custom mixes (M)
- MIDI with chords and notes (C)
- PDF, MusicXML and text (S Pro)

### Other
- Scripting (T)
- Autosaving of loops, markers and settings per song (C)
- Production extras: mastering, voice models, a stems plugin (M), probably out of scope

## Planned high-level features

Curated union of the features from the above apps.

### Import and library
- Session is based on an audio or video file, from as many sources as possible:
  - Disk file
  - Streaming services
  - Audio capture of other apps (browser playing from a streaming service)
  - Import from the Apple Music library
  - Cloud import from Dropbox, Drive, iCloud or a URL
- Sync across devices; sharing projects, marks and loops

### Playback and navigation

- Waveform with scroll and zoom, playhead
- Play from any point, freeze and scrub
- Keyboard shortcuts
- Count-in

### Speed and pitch
- Fully flexible tempo and pitch shift: transpose, cent-level fine-tuning
- Transposing-instrument setting, virtual capo, alternate tunings

### Isolating parts of the audio
- Playback/analysis channel selection: full, L, R, L - R
- AI stem separation with solo, mute and remix
- Mixing in live input with plugin chain

### Analysis
- Beat and bar grid: detected (editable) or by hand
- Tempo/BPM, key, time signature, tuning
- Chord detection (editable), bass notes when not the root, Roman / Nashville notation
- Note and pitch detection
- Various time-frequency distributions (TFDs), spectrum, piano roll
- Lyrics detection

### Annotation and structure
- Custom markers (other than beat/measure/section), named regions
- Text annotations
- Lyrics: importable, editable, scrolling display
- Score and tabs
- Chord diagrams for several instruments, left-handed option
- Drawing notes on the TFD to generate tabs and score
- Separate view modes, e.g. Chords, Tabbing, Structure, Practice

### Practice tools
- Stored, named loops, snap to the beat grid
- Loop trainer with repeat count, tempo ramp and auto-advance
- Metronome synced to the song
- On-screen reference keyboard
- Backing tracks with a part removed

### Export
- Processed audio
- Stems and custom mixes
- MIDI with chords and notes
- PDF, MusicXML and text

### Other
- Scripting
