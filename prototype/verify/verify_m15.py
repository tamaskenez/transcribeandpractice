"""Milestone 15 checks: single-segment notes (session format, drawing, selection and deletion),
creating notes by dragging and editing pitches with the handles.
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


def note(b0, p0, b1, p1, t0='0/1', t1='0/1'):
    return {'start': dict(loc(b0, t0), pitch=p0), 'end': dict(loc(b1, t1), pitch=p1)}


NOTES = [
    note(6, 57, 8, 57),                # A: flat, 3.5–4.5 s
    note(9, 60, 13, 64),               # G: a glide, 5–7 s
    note(16, 58, 16, 61, '0/1', '1/8'),  # S: 1/8 beat at 8.5 s: an ellipse
    note(18, 55, 18, 55, '0/1', '1/2'),  # D: half a beat at 9.5 s: one handle
]


class NoFront(Session):
    def bring_to_front(self):
        pass


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
g = subprocess.run(['grep', '-rnE', r'NoteTrajectory|NotePoint|SegmentRef|\.pre\b|\.post\b|[Tt]ransition|holdTimer|hold timer|pitchCurve'
                    r'|selectedSegment|[Tt]rajector|creationHandles|holdProgress|pieRect', 'Sources/'], capture_output=True, text=True)
check(1, 'no note-trajectory types or code left in the sources', g.stdout == '', g.stdout[:600])
build_driver()
for k in KEYS:
    subprocess.run(['defaults', 'delete', DOMAIN, k], capture_output=True)


def pos(tm):
    """Beat position string of a time on the 0.5 s beats (from 0.5 s), as the dump writes it."""
    from fractions import Fraction
    f = Fraction(tm - 0.5).limit_denominator(64) / Fraction(1, 2)
    return f'{f.numerator}/{f.denominator}'


# 2. Session files: the new format loads; the old points format is rejected.
if run(2):
    write_session(NOTES)
    s = NoFront('load', opens=[AUDIO_PATH])
    s.dump()
    got = [{'start': {k: n['start'][k] for k in ('beat', 'tau', 'pitch')}, 'end': {k: n['end'][k] for k in ('beat', 'tau', 'pitch')}}
           for n in s.state['waveforms']['main']['notes']]
    check(2, 'a session file in the new format loads (start and end locations and pitches as written)',
          got == NOTES and s.state['alertText'] is None, json.dumps(got))
    s.quit()
    json.dump({'beats': BEATS, 'notes': [{'points': [{'beat': 3, 'tau': '0/1', 'pre': 60, 'post': 60}],
                                          'end': {'beat': 4, 'tau': '0/1', 'pitch': 60}}]}, open(SIDE, 'w'))
    s = NoFront('old_format', opens=[AUDIO_PATH])
    s.dump()
    check(2, 'a session file in the old points format is rejected with the alert',
          s.state['alertText'] is not None and s.state['alertTitle'] == 'Could not read the session'
          and s.state['waveforms']['main']['notes'] == [], json.dumps(s.state['alertText']))
    s.quit()

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

    def sel(s):
        return main(s)['selectedNotes']

    def time_of(p):
        return p[0] if hz else p[1]

    def cross_of(p):
        return -p[1] if hz else p[0]  # grows with pitch

    def axis_of(s, tm):
        v0, v1 = s.view()
        return (tm - v0) / (v1 - v0) * s.length('main')

    def bt(b, tau=0.0):
        return 0.5 + 0.5 * (b + tau)

    EDIT_VIEW = '2,10' if hz else '2,12'

    # 3. Drawing and hover; 4. selection and deletion (and the session file written back).
    if run(3) or run(4):
        write_session(NOTES)
        s = session(f'{o}_notes', o, EDIT_VIEW)
        A, G, S, D = notes_of(s)
    if run(3):
        ok, d = True, []
        for name, n, spec in zip('AGSD', (A, G, S, D), NOTES):
            sh = n['shape']
            t0 = bt(spec['start']['beat'], eval(spec['start']['tau']))
            t1 = bt(spec['end']['beat'], eval(spec['end']['tau']))
            dp = spec['end']['pitch'] - spec['start']['pitch']
            k = abs(cross_of(sh['end']) - cross_of(sh['start']) - dp * PPS) <= 1.01 \
                and abs(time_of(sh['start']) - (round(axis_of(s, t0)) + (sh['width'] - 1) / 2)) <= 1.01
            if not sh['ellipse']:
                k = k and abs(time_of(sh['end']) - (round(axis_of(s, t1)) - sh['width'] + (sh['width'] - 1) / 2)) <= 1.01
            ok = ok and k
            d.append(f'{name}:{k}')
        check(3, f'{o}: each note\'s end circles at its start / end (inset by the radius) and its start / end pitch (glide: 4 × 14 points higher)',
              ok, ' '.join(d))
        check(3, f'{o}: A flat; S an ellipse; A three handles, D one, S none',
              A['shape']['start'][1 if hz else 0] == A['shape']['end'][1 if hz else 0] and S['shape']['ellipse']
              and not A['shape']['ellipse'] and len(A['shape']['handles']) == 3 and len(D['shape']['handles']) == 1
              and S['shape']['handles'] == [] and len(G['shape']['handles']) == 3,
              json.dumps([n['shape']['handles'] for n in (A, G, S, D)]))
        s.snapshot('notes')
        s.command('harmonics 3')
        h = G['shape']['handles']
        s.input(f'move {P(scr(s, h[2]))}')
        check(3, f'{o}: over the glide\'s end handle: hovered, its handles drawn, open hand, 2 harmonic copies, no hover cell',
              notes_of(s)[1]['hovered'] and main(s)['handleNote'] == 1 and main(s)['cursor'] == 'openHand'
              and len(main(s)['noteHarmonics']) == 2 and main(s)['hoverCell'] is None,
              f"{main(s)['cursor']} {main(s)['handleNote']} {len(main(s)['noteHarmonics'])}")
        s.snapshot('hover_glide')
        q = ((h[0][0] + h[1][0]) / 2, (h[0][1] + h[1][1]) / 2)
        s.input(f'move {P(scr(s, q))}')
        check(3, f'{o}: on the glide between handles: hovered, arrow', notes_of(s)[1]['hovered'] and main(s)['cursor'] == 'arrow',
              main(s)['cursor'])
        eb = S['shape']['ellipseBox']
        s.input(f'move {P(scr(s, (eb[0] + eb[2] / 2, eb[1] + eb[3] / 2)))}')
        check(3, f'{o}: the ellipse: hovered, no handles, arrow', notes_of(s)[2]['hovered'] and main(s)['cursor'] == 'arrow')
        far = (h[1][0], h[1][1] - 80) if hz else (h[1][0] - 80, h[1][1])
        s.input(f'move {P(scr(s, far))}')
        check(3, f'{o}: away from the notes: nothing hovered, the hover cell with its copies',
              not any(n['hovered'] for n in notes_of(s)) and main(s)['hoverCell'] is not None
              and main(s)['noteHarmonics'] == [], '')
        s.command('harmonics 1')
    if run(4):
        def on(n):
            sh = n['shape']
            if sh['ellipse']:
                b = sh['ellipseBox']
                return P(scr(s, (b[0] + b[2] / 2, b[1] + b[3] / 2)))
            hs = sh['handles']
            h = hs[0] if len(hs) == 1 else hs[1]
            return P(scr(s, (h[0] + 6, h[1]) if hz else (h[0], h[1] + 6)))

        s.input(f'click {on(A)}')
        check(4, f'{o}: a click selects one note', sel(s) == [0], str(sel(s)))
        s.input(f'dclick {on(G)}')
        check(4, f'{o}: a double-click selects one note too', sel(s) == [1], str(sel(s)))
        s.snapshot('selected')
        s.input(f'click {on(A)} cmd', f'click {on(S)} cmd')
        check(4, f'{o}: ⌘-click adds notes', sel(s) == [0, 1, 2], str(sel(s)))
        s.input(f'click {on(G)} cmd')
        check(4, f'{o}: ⌘-click removes a note', sel(s) == [0, 2], str(sel(s)))
        s.input('key escape')
        check(4, f'{o}: Escape clears the selection', sel(s) == [], str(sel(s)))
        a, dd = A['rect'], D['rect']
        x0, y0 = min(a[0], dd[0]) - 6, min(a[1], dd[1]) - 6
        x1, y1 = max(a[0] + a[2], dd[0] + dd[2]) + 6, max(a[1] + a[3], dd[1] + dd[3]) + 6
        ax1, ay1 = a[0] + a[2] + 6, a[1] + a[3] + 6
        s.input(f'down {P(scr(s, (x0, y0)))} shift', f'dragto {P(scr(s, (x1, y1)))}')
        check(4, f'{o}: ⇧-drag around A and D: both selected live, the rectangle shown',
              sel(s) == [0, 3] and main(s)['noteBand'] is not None, str(sel(s)))
        s.snapshot('band')
        s.input(f'dragto {P(scr(s, (ax1, ay1)))}')
        check(4, f'{o}: shrunk to A: D unselected again', sel(s) == [0], str(sel(s)))
        s.input(f'up {P(scr(s, (ax1, ay1)))}')
        check(4, f'{o}: on release the selection stays, the rectangle is gone', sel(s) == [0] and main(s)['noteBand'] is None)
        s.input('key backspace')
        check(4, f'{o}: Backspace deletes A, saved (the rest written back in the same format)',
              saved_notes() == NOTES[1:] and len(notes_of(s)) == 3 and sel(s) == [], json.dumps(saved_notes()))
        beeps = s.state['beepCount']
        s.command('beatsel 7'); s.command('beatmenu Delete'); s.dump()
        check(4, f'{o}: A\'s beat 7 is free now and can be deleted', len(s.state['beats']) == 37 and s.state['beepCount'] == beeps)
    if run(3) or run(4):
        s.quit()

    # Creation: the view keeps cells wider than a capsule and clear of the spectrum pane.
    VIEW = '1.5,7.5' if hz else '2,7.5'

    # 5. Creating by dragging; a click places the one-cell note.
    if run(5) or run(6):
        write_session([])
        s = session(f'{o}_drag', o, VIEW)
        M = mid_note(s)
    if run(5):
        s.input(f'down {at(s, 3.1, M)}', f'dragto {at(s, 3.85, M + 2)}')
        c = cr(s)
        check(5, f'{o}: dragging: the note runs from the press cell\'s start to the pointer cell\'s end, 2 semitones up',
              c is not None and c['startPos'] == pos(3.0) and c['endPos'] == pos(4.0) and c['startPitch'] == M
              and c['endPitch'] == M + 2 and c['valid'], json.dumps(c))
        check(5, f'{o}: its end handle is drawn; no hover cell; arrow',
              c is not None and c['handle'] is not None and main(s)['hoverCell'] is None and main(s)['cursor'] == 'arrow'
              and abs((c['handle'][0] if hz else c['handle'][1]) - (c['shape']['end'][0 if hz else 1] + 0.5)) < 0.01,
              json.dumps(c and c['handle']))
        s.snapshot('glide_drag')
        s.input(f'up {at(s, 3.85, M + 2)}')
        check(5, f'{o}: on release the note is added (start pitch = the press note, end pitch +2), saved, nothing selected',
              saved_notes() == [note(5, M, 7, M + 2)] and cr(s) is None and sel(s) == [], json.dumps(saved_notes()))
        s.input(f'click {at(s, 5.1, M)}')
        check(5, f'{o}: a click without moving places the one-cell note',
              saved_notes()[1:] == [note(9, M, 9, M, '0/1', '1/2')], json.dumps(saved_notes()))
    # 6. Invalid places, Escape, overlap.
    if run(6):
        n0 = len(saved_notes())
        # The driver's drags pass intermediate points: compare within the invalid area.
        s.input(f'down {at(s, 2.6, M)}', f'dragto {at(s, 2.9, M)}', f'dragto {at(s, 2.4, M)}')
        before = cr(s)
        s.input(f'dragto {at(s, 2.3, M + 3)}')
        c = cr(s)
        check(6, f'{o}: the pointer before the start cell: the note stays as it was, invalid',
              c['endPos'] == before['endPos'] and c['endPitch'] == before['endPitch'] and not c['valid'], json.dumps(c))
        s.input(f'dragto {at(s, 2.9, M + 1)}')
        before = cr(s)
        spec = [(8.0 + dx, scr(s, vp(s, 3.5, M + dm))[1]) if hz else
                (scr(s, vp(s, 3.5, M + dm))[0], scr(s, (0, main(s)['size']['height'] - 8 + dx))[1]) for dx, dm in ((0, 0), (4, 3))]
        s.input(f'dragto {P(spec[0])}')
        before = cr(s)
        s.input(f'dragto {P(spec[1])}')
        c = cr(s)
        check(6, f'{o}: under the spectrum pane: the note stays, invalid', c['endPos'] == before['endPos'] and not c['valid'],
              json.dumps(c))
        s.input(f'dragto {at(s, 4.1, M)}')
        c = cr(s)
        check(6, f'{o}: back over a valid cell (over an existing note) it follows again', c['endPos'] == pos(4.25) and c['valid'],
              json.dumps(c))
        s.input(f'up {at(s, 4.1, M)}')
        check(6, f'{o}: released: added, overlapping the existing note',
              len(saved_notes()) == n0 + 1 and saved_notes()[-1] == note(4, M, 7, M, '0/1', '1/2'), json.dumps(saved_notes()))
        s.input(f'down {at(s, 5.1, M - 4)}', f'dragto {at(s, 5.6, M - 4)}', f'dragto {at(s, 4.6, M - 4)}', f'up {at(s, 4.6, M - 4)}')
        check(6, f'{o}: a release while invalid adds nothing', len(saved_notes()) == n0 + 1, json.dumps(saved_notes()))
        s.input(f'down {at(s, 5.1, M - 4)}', f'dragto {at(s, 5.6, M - 3)}')
        valid = cr(s) is not None and cr(s)['valid']
        s.input('key escape')
        esc = cr(s) is None
        s.input(f'up {at(s, 5.6, M - 3)}')
        check(6, f'{o}: Escape mid-drag adds nothing (also not on the release)', valid and esc and len(saved_notes()) == n0 + 1,
              json.dumps(saved_notes()))
    if run(5) or run(6):
        s.quit()
    if run(6):
        write_session([])
        s = session(f'{o}_end', o, '16,20' if hz else '17,20.05')
        M = mid_note(s)
        s.input(f'down {at(s, 18.3, M)}', f'dragto {at(s, 18.4, M)}', f'dragto {at(s, 19.1, M)}')
        before = cr(s)
        s.input(f'dragto {at(s, 19.15, M + 3)}')
        c = cr(s)
        check(6, f'{o}: after the last beat: the note stays, invalid', c['endPos'] == before['endPos'] and not c['valid'],
              json.dumps(c))
        s.input(f'dragto {at(s, 18.9, M)}')
        c = cr(s)
        check(6, f'{o}: the last cell is valid again (ends at the last beat)', c['endPos'] == pos(19.0) and c['valid'], json.dumps(c))
        s.input(f'dragto {at(s, 19.1, M)}', f'up {at(s, 19.1, M)}')
        check(6, f'{o}: released after the last beat: nothing added', saved_notes() == [], json.dumps(saved_notes()))
        s.quit()

    # 7. Editing pitches with the handles.
    if run(7):
        write_session(NOTES)
        s = session(f'{o}_edit', o, EDIT_VIEW)
        up = (0, -2 * PPS) if hz else (2 * PPS, 0)

        def handle(i, which):
            hs = notes_of(s)[i]['shape']['handles']
            return hs[{'start': 0, 'middle': 1, 'end': 2}[which]] if len(hs) == 3 else hs[0]

        def pitches(n):
            return n['start']['pitch'], n['end']['pitch']

        steps = [(1, 'start', (62, 64), 'the glide\'s start handle: only its start pitch'),
                 (1, 'end', (62, 66), 'the end handle: only its end pitch'),
                 (1, 'middle', (64, 68), 'the middle handle: both'),
                 (3, 'middle', (57, 57), 'a short note\'s only handle: both')]
        for i, (idx, which, want, desc) in enumerate(steps):
            h = handle(idx, which)
            target = P(scr(s, (h[0] + up[0], h[1] + up[1])))
            s.input(f'down {P(scr(s, h))}', f'dragto {target}')
            cursor, he, sl = main(s)['cursor'], main(s)['handleEdit'], sel(s)
            if i == 2:
                s.snapshot('handle_drag')
            s.input(f'up {target}')
            got = pitches(saved_notes()[idx])
            check(7, f'{o}: {desc}; selects only that note; closed hand while dragging; saved',
                  got == want and cursor == 'closedHand' and he is not None and he['offset'] == 2 and sl == [idx]
                  and pitches(saved_notes()[0]) == (57, 57), f'{got} {cursor} {he} {sl}')
        before = saved_notes()
        h = handle(0, 'middle')
        target = P(scr(s, (h[0] + 1.5 * up[0], h[1] + 1.5 * up[1])))
        s.input(f'down {P(scr(s, h))}', f'dragto {target}')
        moved = main(s)['handleEdit']
        s.input('key escape')
        a_now = notes_of(s)[0]
        s.input(f'up {target}')
        check(7, f'{o}: Escape mid-drag restores the pitches', moved is not None and moved['offset'] == 3
              and main(s)['handleEdit'] is None and saved_notes() == before and pitches(a_now) == (57, 57), f'{moved} {pitches(a_now)}')
        locs = [(n['start']['beat'], n['start']['tau'], n['end']['beat'], n['end']['tau']) for n in saved_notes()]
        check(7, f'{o}: locations never changed',
              locs == [(n['start']['beat'], n['start']['tau'], n['end']['beat'], n['end']['tau']) for n in NOTES], json.dumps(locs))
        s.quit()

print(f'{sum(results)}/{len(results)} passed')
