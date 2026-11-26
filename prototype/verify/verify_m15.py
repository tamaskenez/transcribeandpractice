"""Milestone 15 checks: creating notes by dragging (the hold timer, multi-segment notes) and editing
pitches with the handles.
Run from prototype/: python3 verify/verify_m15.py

Needs Accessibility and Screen Recording permission for the terminal. Don't touch the mouse or
keyboard while it runs. Screenshots: verify/out/m15/*.png. ONLY=2,4 runs selected criteria;
ORIENT=horizontal runs one orientation.
"""
import atexit, json, os, subprocess, sys
import numpy as np

sys.path.insert(0, os.path.dirname(__file__))
import m3session  # noqa: E402
import m4util  # noqa: E402
from m4util import Session, build_driver, check, results, DOMAIN  # noqa: E402
from gen_test_audio_m2 import write_float_wav  # noqa: E402

OUT = 'verify/out/m15'
os.makedirs(OUT, exist_ok=True)
m3session.OUT = m4util.OUT = OUT
DRIVER = m3session.DRIVER = f'{OUT}/inputdriver'
AUDIO = os.path.abspath(f'{OUT}/audio')
ONLY = set(os.environ.get('ONLY', '').split(',')) - {''}
ORIENTATIONS = tuple(os.environ.get('ORIENT', 'horizontal,vertical').split(','))
SR = 44100
KEYS = ['timeOrientation', 'followPlayhead', 'mainPaneMode', 'showBeats', 'gridKind', 'gridStraight', 'harmonics']
LOWEST = 21
PPS = 14


def run(c):
    return not ONLY or str(c) in ONLY


def kill_leftovers():
    subprocess.run(['pkill', '-f', '^build/TranscribeAndPractice[.]app/'], capture_output=True)


saved = {}
for k in KEYS:
    r = subprocess.run(['defaults', 'read-type', DOMAIN, k], capture_output=True, text=True)
    v = subprocess.run(['defaults', 'read', DOMAIN, k], capture_output=True, text=True)
    if r.returncode == 0 and v.returncode == 0:
        saved[k] = (r.stdout.strip().split()[-1], v.stdout.strip())


def restore_defaults():
    for k in KEYS:
        subprocess.run(['defaults', 'delete', DOMAIN, k], capture_output=True)
        if k in saved:
            kind, v = saved[k]
            flag = {'boolean': '-bool', 'integer': '-int', 'float': '-float'}.get(kind, '-string')
            if flag == '-bool':
                v = 'true' if v == '1' else 'false'
            subprocess.run(['defaults', 'write', DOMAIN, k, flag, v], capture_output=True)


kill_leftovers()
atexit.register(kill_leftovers)
atexit.register(restore_defaults)

os.makedirs(AUDIO, exist_ok=True)
rng = np.random.default_rng(15)
AUDIO_PATH = f'{AUDIO}/notes.wav'
t = np.arange(SR * 20) / SR
sig = 0.2 * np.sin(2 * np.pi * 440 * t) + 0.005 * rng.standard_normal(len(t))
write_float_wav(AUDIO_PATH, sig.astype(np.float32)[:, None], SR)
SIDE = AUDIO_PATH + '.session.json'
BEATS = [{'sample': int(round((0.5 + 0.5 * k) * SR)), 'firstBeat': 'auto'} for k in range(38)]  # last beat: 19 s


def write_session(notes):
    json.dump({'beats': BEATS, 'notes': notes}, open(SIDE, 'w'))


def saved_notes():
    return json.load(open(SIDE))['notes']


def loc(b, tau='0/1'):
    return {'beat': b, 'tau': tau}


def pt(b, pre, post, tau='0/1'):
    return dict(loc(b, tau), pre=pre, post=post)


# Milestone 14's notes A, B, D (for editing).
NOTES = [
    {'points': [pt(6, 57, 57)], 'end': dict(loc(8), pitch=57)},
    {'points': [pt(9, 60, 62), pt(11, 64, 66), pt(13, 66, 63)], 'end': dict(loc(15), pitch=63)},
    {'points': [pt(18, 55, 55)], 'end': dict(loc(18, '1/2'), pitch=55)},
]


def P(xy):
    return f'{xy[0]:.1f} {xy[1]:.1f}'


def session(name, o, view):
    s = Session(name, opens=[AUDIO_PATH], orientation=o)
    s.command('resize 1000,700')
    s.command('follow off')
    s.command('mode spectrogram')
    s.command('beats on')
    s.command('grid straight 8')  # two cells per beat: 0.25 s
    s.command('harmonics 1')
    s.command(f'view {view}')
    s.command('playhead 1')
    s.dump()
    return s


r = subprocess.run(['./build.sh'], capture_output=True, text=True)
check(1, 'builds', r.returncode == 0 and 'error' not in r.stdout + r.stderr, r.stdout[-400:] + r.stderr[-400:])
build_driver()
for k in KEYS:
    subprocess.run(['defaults', 'delete', DOMAIN, k], capture_output=True)


def pos(tm):
    """Beat position string of a time on the 0.5 s beats (from 0.5 s), as the dump writes it."""
    from fractions import Fraction
    f = Fraction(tm - 0.5).limit_denominator(64) / Fraction(1, 2)
    return f'{f.numerator}/{f.denominator}'


for o in ORIENTATIONS:
    hz = o == 'horizontal'

    def main(s):
        return s.state['waveforms']['main']

    def notes_of(s):
        return main(s)['notes']

    def cr(s):
        return main(s)['creation']

    def vp(s, tm, midi):
        """View point at a time and the middle of a MIDI note."""
        v0, v1 = s.view()
        a = (tm - v0) / (v1 - v0) * s.length('main')
        c = (midi - LOWEST + 0.5 - s.state['spectrogram']['freqView']['low']) * PPS
        size = main(s)['size']
        return (a, size['height'] - c) if hz else (c, a)

    def scr(s, p):
        fr = s.state['screenFrames']['main']
        return fr['x'] + p[0], fr['y'] + p[1]

    def at(s, tm, midi):
        return P(scr(s, vp(s, tm, midi)))

    def handle_pt(s):
        h = cr(s)['handle']
        return P(scr(s, (h[0], h[1])))

    def mid_note(s):
        fv = s.state['spectrogram']['freqView']
        return LOWEST + int((fv['low'] + fv['high']) / 2)

    # Creation: the view keeps cells wider than a capsule (vertical: less room for the pane).
    VIEW = '1.5,7.5' if hz else '2,7.5'

    # 2. One segment by dragging; a click still places a one-cell note.
    if run(2) or run(3):
        write_session([])
        s = session(f'{o}_drag', o, VIEW)
        M = mid_note(s)
    if run(2):
        s.input(f'down {at(s, 3.1, M)}', f'dragto {at(s, 3.85, M + 2)}')
        c = cr(s)
        check(2, f'{o}: dragging: the current segment runs from the press cell\'s start to the pointer cell\'s end, 2 semitones up',
              c is not None and c['startPos'] == pos(3.0) and c['endPos'] == pos(4.0) and c['current']['post'] == M
              and c['endPitch'] == M + 2 and c['firstFixed'] and c['valid'] and not c['finished'], json.dumps(c))
        check(2, f'{o}: the second point\'s handle is drawn at the segment\'s end; no hover cell',
              c is not None and c['handle'] is not None and main(s)['hoverCell'] is None
              and abs((c['handle'][0] if hz else c['handle'][1]) - (c['segments'][-1]['end'][0 if hz else 1] + 0.5)) < 0.01,
              json.dumps(c and c['handle']))
        s.snapshot('glide_drag')
        s.input(f'up {at(s, 3.85, M + 2)}')
        want = {'points': [pt(5, M, M)], 'end': dict(loc(7), pitch=M + 2)}
        check(2, f'{o}: on release one note (pre = post = the press note, end pitch +2), saved, nothing selected',
              saved_notes() == [want] and cr(s) is None and main(s)['selectedSegments'] == [], json.dumps(saved_notes()))
        s.input(f'click {at(s, 5.1, M)}')
        check(2, f'{o}: a click without moving places the one-cell note',
              saved_notes()[1:] == [{'points': [pt(9, M, M)], 'end': dict(loc(9, '1/2'), pitch=M)}], json.dumps(saved_notes()))
    # 3. Invalid places; overlapping an existing note.
    if run(3):
        n0 = len(saved_notes())
        s.input(f'down {at(s, 2.6, M)}', f'dragto {at(s, 2.9, M)}')
        before = cr(s)
        s.input(f'dragto {at(s, 2.4, M + 3)}')
        c = cr(s)
        check(3, f'{o}: the pointer before the start cell: the segment stays as it was, invalid',
              c['endPos'] == before['endPos'] and c['endPitch'] == before['endPitch'] and not c['valid'], json.dumps(c))
        spec = (8.0, scr(s, vp(s, 3.5, M))[1]) if hz else (scr(s, vp(s, 3.5, M))[0], scr(s, (0, main(s)['size']['height'] - 8))[1])
        s.input(f'dragto {P(spec)}')
        c = cr(s)
        check(3, f'{o}: under the spectrum pane: the segment stays, invalid',
              c['endPos'] == before['endPos'] and not c['valid'], json.dumps(c))
        s.input(f'dragto {at(s, 4.1, M)}')
        c = cr(s)
        check(3, f'{o}: back over a valid cell it follows again (over the existing note)',
              c['endPos'] == pos(4.25) and c['valid'], json.dumps(c))
        s.input(f'up {at(s, 4.1, M)}')
        check(3, f'{o}: the note was added, overlapping the existing one',
              len(saved_notes()) == n0 + 1 and saved_notes()[-1] == {'points': [pt(4, M, M)], 'end': dict(loc(7, '1/2'), pitch=M)},
              json.dumps(saved_notes()))
        s.input(f'down {at(s, 5.1, M - 4)}', f'dragto {at(s, 5.6, M - 4)}', f'dragto {at(s, 4.6, M - 4)}', f'up {at(s, 4.6, M - 4)}')
        check(3, f'{o}: a release while invalid (no finished segments) adds nothing', len(saved_notes()) == n0 + 1,
              json.dumps(saved_notes()))
    if run(2) or run(3):
        s.quit()

    # 4. The hold timer on the second point's handle.
    if run(4):
        write_session([])
        s = session(f'{o}_hold', o, VIEW)
        M = mid_note(s)
        s.input(f'down {at(s, 3.1, M)}', f'dragto {at(s, 3.6, M)}')
        c = cr(s)
        end0 = c['endPos']
        s.input(f'dragto {handle_pt(s)}', 'sleep 500')
        c = cr(s)
        pie = c['pie']
        px, py = c['pointer']
        check(4, f'{o}: on the handle the timer runs; the pie beside the pointer (+16, +16)',
              c['timerRunning'] and c['holdProgress'] is not None and 0.4 < c['holdProgress'] < 0.95 and pie is not None
              and abs(pie[0] + 7 - px - 16) < 0.01 and abs(pie[1] + 7 - py - 16) < 0.01 and pie[2] == 14,
              json.dumps({k: c[k] for k in ('holdProgress', 'pie', 'pointer', 'timerRunning')}))
        s.snapshot('pie')
        h = c['handle']
        off = (h[0] - 9, h[1]) if hz else (h[0], h[1] - 9)
        s.input(f'dragto {P(scr(s, off))}', 'sleep 800')
        c = cr(s)
        check(4, f'{o}: leaving after 0.5 s stops and hides the timer and changes nothing',
              c['holdProgress'] is None and c['pie'] is None and not c['timerRunning'] and c['endPos'] == end0
              and c['firstFixed'] and not c['finished'], json.dumps(c))
        s.input(f'dragto {handle_pt(s)}', 'sleep 1200')
        c = cr(s)
        check(4, f'{o}: staying 1 s finalises the segment: a new point at its end, the next cell, first point not fixed, invalid',
              len(c['finished']) == 1 and c['current']['pos'] == end0 and c['startPos'] == end0 and c['endPos'] == pos(4.0)
              and c['current']['pre'] == M and not c['firstFixed'] and not c['valid'], json.dumps(c))
        hx = c['handle']
        check(4, f'{o}: the first point\'s handle is drawn (at the new segment\'s start); no timer running',
              hx is not None and abs((hx[0] if hz else hx[1]) - (c['segments'][-1]['start'][0 if hz else 1] + 0.5)) < 0.01
              and c['holdProgress'] is None and not c['timerRunning'], json.dumps(c))
        s.input(f'up {P(scr(s, c["pointer"]))}')
        check(4, f'{o}: a release right then adds the note with only the finalised segment',
              saved_notes() == [{'points': [pt(5, M, M)], 'end': dict(loc(6, '1/2'), pitch=M)}], json.dumps(saved_notes()))
        s.quit()

    # 5. A multi-segment note; Escape; harmonic copies.
    if run(5):
        write_session([])
        s = session(f'{o}_multi', o, VIEW)
        M = mid_note(s)
        s.command('harmonics 3')
        s.input(f'down {at(s, 3.1, M)}', f'dragto {at(s, 3.6, M)}')
        s.input(f'dragto {handle_pt(s)}', 'sleep 1200')
        s.input(f'dragto {at(s, 4.1, M - 3)}')
        c = cr(s)
        check(5, f'{o}: two cells on, 3 semitones down: flat at the new note, pre = the previous end pitch',
              c['current']['pre'] == M and c['current']['post'] == M - 3 and c['endPitch'] == M - 3 and c['endPos'] == pos(4.25)
              and c['valid'] and not c['firstFixed'], json.dumps(c))
        check(5, f'{o}: while creating: the note\'s 2 harmonic copies, no hover cell',
              len(main(s)['noteHarmonics']) == 2 and main(s)['hoverCell'] is None, json.dumps(main(s)['noteHarmonics']))
        s.snapshot('not_fixed')
        s.input(f'dragto {handle_pt(s)}', 'sleep 1200')
        c = cr(s)
        check(5, f'{o}: the timer on the first point\'s handle fixes the first point',
              c['firstFixed'] and c['current']['post'] == M - 3, json.dumps(c))
        s.input(f'dragto {at(s, 3.9, M - 3)}', f'dragto {at(s, 4.35, M - 2)}')
        c = cr(s)
        check(5, f'{o}: then one cell on and a semitone up: a glide',
              c['current']['post'] == M - 3 and c['endPitch'] == M - 2 and c['endPos'] == pos(4.5) and c['valid'], json.dumps(c))
        s.snapshot('glide_second')
        s.input(f'up {at(s, 4.35, M - 2)}')
        want = {'points': [pt(5, M, M), pt(6, M, M - 3, '1/2')], 'end': dict(loc(8), pitch=M - 2)}
        check(5, f'{o}: the release adds the two-point note, saved', saved_notes() == [want], json.dumps(saved_notes()))
        s.input(f'move {at(s, 3.3, M)}')
        s.snapshot('finished_harmonics')
        # Escape during a later drag: only the current segment is dropped.
        s.input(f'down {at(s, 5.1, M + 4)}', f'dragto {at(s, 5.35, M + 4)}')
        s.input(f'dragto {handle_pt(s)}', 'sleep 1200')
        s.input(f'dragto {at(s, 5.85, M + 5)}')
        s.input('key escape')
        check(5, f'{o}: Escape drops only the current segment (the finalised one is added)',
              cr(s) is None and saved_notes()[1:] == [{'points': [pt(9, M + 4, M + 4)], 'end': dict(loc(10), pitch=M + 4)}],
              json.dumps(saved_notes()))
        s.input(f'up {at(s, 5.85, M + 5)}')
        check(5, f'{o}: the release after Escape adds nothing more', len(saved_notes()) == 2, json.dumps(saved_notes()))
        # First point not fixed: the second point's handle is drawn too, and its timer finalises.
        s.input(f'down {at(s, 2.6, M - 8)}', f'dragto {handle_pt(s)}', 'sleep 1200', f'dragto {at(s, 3.1, M - 6)}')
        c = cr(s)
        check(5, f'{o}: not fixed: both handles drawn', not c['firstFixed'] and c['handle'] is not None
              and c['secondHandle'] is not None and c['secondHandle'] != c['handle'][:2], json.dumps(c))
        sh = c['secondHandle']
        s.input(f'dragto {P(scr(s, sh))}', 'sleep 1200')
        c = cr(s)
        check(5, f'{o}: the timer on the second point\'s handle (first point not fixed) finalises the segment; the next one not fixed',
              len(c['finished']) == 2 and c['finished'][1]['post'] == M - 6 and c['startPos'] == pos(3.25)
              and c['current']['pre'] == M - 6 and not c['firstFixed'], json.dumps(c))
        s.input(f'up {P(scr(s, sh))}')
        check(5, f'{o}: released: the two finalised segments', saved_notes()[2:] ==
              [{'points': [pt(4, M - 8, M - 8), pt(4, M - 8, M - 6, '1/2')], 'end': dict(loc(5, '1/2'), pitch=M - 6)}],
              json.dumps(saved_notes()))
        s.command('harmonics 1')
        s.quit()

    # 6. The end of the beats (the last beat at 19 s).
    if run(6):
        write_session([])
        s = session(f'{o}_end', o, '16,20' if hz else '17,20.05')
        M = mid_note(s)
        s.input(f'down {at(s, 18.3, M)}', f'dragto {at(s, 18.4, M)}')
        before = cr(s)
        s.input(f'dragto {at(s, 19.1, M)}')
        c = cr(s)
        check(6, f'{o}: after the last beat: the segment stays, invalid', c['endPos'] == before['endPos'] and not c['valid'],
              json.dumps(c))
        s.input(f'up {at(s, 19.1, M)}')
        check(6, f'{o}: released there: nothing added', saved_notes() == [], json.dumps(saved_notes()))
        s.input(f'down {at(s, 18.8, M)}', f'dragto {at(s, 18.85, M)}', f'dragto {handle_pt(s)}', 'sleep 1200')
        want = {'points': [pt(36, M, M, '1/2')], 'end': dict(loc(37), pitch=M)}
        c = cr(s)
        check(6, f'{o}: the timer on the last cell\'s handle: the note is added and saved at once',
              saved_notes() == [want] and c is not None and c['complete'], json.dumps(saved_notes()))
        s.input(f'dragto {at(s, 18.3, M + 2)}', f'up {at(s, 18.3, M + 2)}')
        check(6, f'{o}: moving and releasing change nothing more', saved_notes() == [want] and cr(s) is None,
              json.dumps(saved_notes()))
        s.quit()

    # 7. Editing pitches with the handles.
    if run(7):
        write_session(NOTES)
        s = session(f'{o}_edit', o, '2,10' if hz else '2,12')
        up = (0, -2 * PPS) if hz else (2 * PPS, 0)
        locs0 = [([(p['beat'], p['tau']) for p in n['points']], n['end']['beat'], n['end']['tau']) for n in NOTES]

        def handle(note, k, which):
            hs = notes_of(s)[note]['segments'][k]['handles']
            return hs[{'start': 0, 'middle': 1, 'end': 2}[which]] if len(hs) == 3 else hs[0]

        def drag_handle(note, k, which, snap=None):
            h = handle(note, k, which)
            s.input(f'down {P(scr(s, h))}', f'dragto {P(scr(s, (h[0] + up[0], h[1] + up[1])))}')
            mid = (main(s)['cursor'], main(s)['handleEdit'], main(s)['selectedSegments'])
            if snap:
                s.snapshot(snap)
            s.input(f'up {P(scr(s, (h[0] + up[0], h[1] + up[1])))}')
            return mid

        def pitches(n):
            return [(p['pre'], p['post']) for p in n['points']], n['end']['pitch']

        steps = [  # (note, segment, handle, expected B / D pitches after the drag)
            (1, 1, 'start', 1, ([(60, 62), (64, 68), (66, 63)], 63), 'B middle segment, start handle: only point 1\'s post'),
            (1, 1, 'end', 1, ([(60, 62), (64, 68), (68, 63)], 63), 'B middle segment, end handle: only point 2\'s pre'),
            (1, 1, 'middle', 1, ([(60, 62), (64, 70), (70, 63)], 63), 'B middle segment, middle handle: both'),
            (1, 2, 'end', 1, ([(60, 62), (64, 70), (70, 63)], 65), 'B last segment, end handle: the end pitch'),
            (1, 0, 'start', 1, ([(62, 64), (64, 70), (70, 63)], 65), 'B first segment, start handle: point 0\'s pre and post'),
            (2, 0, 'middle', 2, ([(57, 57)], 57), 'D\'s only handle: both of its pitches'),
        ]
        for i, (note, k, which, idx, want, desc) in enumerate(steps):
            cursor, he, sel = drag_handle(note, k, which, snap='handle_drag' if i == 2 else None)
            got = pitches(saved_notes()[idx])
            check(7, f'{o}: {desc}; selects only that segment; closed hand while dragging; saved',
                  got == want and cursor == 'closedHand' and he is not None and he['offset'] == 2 and sel == [[note, k]]
                  and pitches(saved_notes()[0]) == ([(57, 57)], 57),
                  f'{got} {cursor} {he} {sel}')
        # Escape mid-drag restores; resting on a handle starts no timer.
        before = saved_notes()
        h = handle(0, 0, 'middle')
        s.input(f'down {P(scr(s, h))}', f'dragto {P(scr(s, (h[0] + 1.5 * up[0], h[1] + 1.5 * up[1])))}')
        moved = main(s)['handleEdit']
        s.input('key escape')
        a_now = notes_of(s)[0]
        s.input(f'up {P(scr(s, (h[0] + 1.5 * up[0], h[1] + 1.5 * up[1])))}')
        check(7, f'{o}: Escape mid-drag restores the pitches', moved is not None and moved['offset'] == 3
              and main(s)['handleEdit'] is None and saved_notes() == before and a_now['points'][0]['post'] == 57
              and a_now['end']['pitch'] == 57, f'{moved} {a_now["points"]}')
        s.input(f'move {P(scr(s, h))}', 'sleep 1500')
        hover_ok = main(s)['creation'] is None and main(s)['cursor'] == 'openHand'
        s.input(f'down {P(scr(s, h))}', 'sleep 1500', f'up {P(scr(s, h))}')
        check(7, f'{o}: resting 1.5 s on an existing note\'s handle (hovering or pressed) starts no timer, changes nothing',
              hover_ok and main(s)['creation'] is None and saved_notes() == before, main(s)['cursor'])
        now = saved_notes()
        locs1 = [([(p['beat'], p['tau']) for p in n['points']], n['end']['beat'], n['end']['tau']) for n in now]
        check(7, f'{o}: time locations never changed', locs1 == locs0, json.dumps(locs1))
        s.quit()

print(f'{sum(results)}/{len(results)} passed')
