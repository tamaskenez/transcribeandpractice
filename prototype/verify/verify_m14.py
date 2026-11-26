"""Milestone 14 checks (in progress): note rendering (segments, pre → post capsules, ellipses),
the hovered segment's handles and the hand cursor.
Run from prototype/: python3 verify/verify_m14.py

Needs Accessibility and Screen Recording permission for the terminal. Don't touch the mouse or
keyboard while it runs. Screenshots: verify/out/m14/*.png. ONLY=2,4 runs selected criteria.
"""
import atexit, json, math, os, subprocess, sys
import numpy as np

sys.path.insert(0, os.path.dirname(__file__))
import m3session  # noqa: E402
import m4util  # noqa: E402
from m4util import Session, build_driver, check, results, DOMAIN  # noqa: E402
from gen_test_audio_m2 import write_float_wav  # noqa: E402

OUT = 'verify/out/m14'
os.makedirs(OUT, exist_ok=True)
m3session.OUT = m4util.OUT = OUT
DRIVER = m3session.DRIVER = f'{OUT}/inputdriver'
AUDIO = os.path.abspath(f'{OUT}/audio')
ONLY = set(os.environ.get('ONLY', '').split(',')) - {''}
ORIENTATIONS = ('horizontal', 'vertical')
SR = 44100
KEYS = ['timeOrientation', 'followPlayhead', 'mainPaneMode', 'showBeats', 'gridKind', 'gridStraight', 'harmonics']
LOWEST = 21


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
rng = np.random.default_rng(14)
AUDIO_PATH = f'{AUDIO}/notes.wav'
t = np.arange(SR * 20) / SR
sig = 0.2 * np.sin(2 * np.pi * 440 * t) + 0.005 * rng.standard_normal(len(t))
write_float_wav(AUDIO_PATH, sig.astype(np.float32)[:, None], SR)
SIDE = AUDIO_PATH + '.session.json'
# Beats every 0.5 s from 0.5 s, bar starts every 4 (4/4): 1/16 grid = 0.125 s.
json.dump({'beats': [{'sample': int(round((0.5 + 0.5 * k) * SR)), 'firstBeat': 'auto'} for k in range(38)], 'notes': []},
          open(SIDE, 'w'))


def session(name, o, mode='spectrogram'):
    s = Session(name, opens=[AUDIO_PATH], orientation=o)
    s.command('resize 1000,700')
    s.command('follow off')
    s.command(f'mode {mode}')
    s.command('beats on')
    s.command('grid straight 16')
    s.command('view 0,10')
    s.command('playhead 2')
    s.dump()
    return s


def P(xy):
    return f'{xy[0]:.1f} {xy[1]:.1f}'


def main_point(s, tm, cross):
    v0, v1 = s.view()
    return s.at('main', (tm - v0) / (v1 - v0), cross)


def view_to_screen(s, p):
    fr = s.state['screenFrames']['main']
    return fr['x'] + p[0], fr['y'] + p[1]


def loc(b, tau='0/1'):
    return {'beat': b, 'tau': tau}


def pt(b, pre, post, tau='0/1'):
    return dict(loc(b, tau), pre=pre, post=post)


NOTES = [
    # A: flat, beats 6 → 8 (3.5–4.5 s).
    {'points': [pt(6, 57, 57)], 'end': dict(loc(8), pitch=57)},
    # B: three segments 9 → 11 → 13 → 15 (5–8 s); pre ≠ post at every point; segment 0 slopes 62 → 64.
    {'points': [pt(9, 60, 62), pt(11, 64, 66), pt(13, 66, 63)], 'end': dict(loc(15), pitch=63)},
    # C: two 1/8-beat segments at beat 16 (8.5 s): ellipses, so no pre → post capsules.
    {'points': [pt(16, 57, 58), pt(16, 60, 61, '1/8')], 'end': dict(loc(16, '1/4'), pitch=61)},
    # D: half a beat at beat 18 (9.5–9.75 s): between 1 and 3 widths long.
    {'points': [pt(18, 55, 55)], 'end': dict(loc(18, '1/2'), pitch=55)},
]


def write_session(notes):
    json.dump({'beats': [{'sample': int(round((0.5 + 0.5 * k) * SR)), 'firstBeat': 'auto'} for k in range(38)],
               'notes': notes}, open(SIDE, 'w'))


def notes_of(s):
    return s.state['waveforms']['main']['notes']


def axis_of(s, tm):
    v0, v1 = s.view()
    return (tm - v0) / (v1 - v0) * s.length('main')


def beat_time(b, tau=0.0):
    return 0.5 + 0.5 * (b + tau)


r = subprocess.run(['./build.sh'], capture_output=True, text=True)
check(1, 'builds', r.returncode == 0 and 'error' not in r.stdout + r.stderr, r.stdout[-400:] + r.stderr[-400:])
build_driver()
for k in KEYS:
    subprocess.run(['defaults', 'delete', DOMAIN, k], capture_output=True)

for o in ORIENTATIONS:
    hz = o == 'horizontal'
    write_session(NOTES)
    s = session(f'{o}_render', o)
    # Vertical: the spectrum pane covers the pane's bottom, so the view reaches further.
    s.command('view 2,10' if hz else 'view 2,12'); s.dump()
    n = notes_of(s)
    A, B, C, D = n

    def time_of(p):
        return p[0] if hz else p[1]

    def cross_of(p):
        return -p[1] if hz else p[0]  # grows with pitch

    # 2. Shapes.
    if run(2):
        ok, d = True, []
        for name, note, spec in zip('ABCD', n, NOTES):
            pts = spec['points']
            pitches = [(p['post'], (pts[k + 1]['pre'] if k + 1 < len(pts) else spec['end']['pitch'])) for k, p in enumerate(pts)]
            locs = [beat_time(p['beat'], eval(p['tau'])) for p in pts] + [beat_time(spec['end']['beat'], eval(spec['end']['tau']))]
            for k, sg in enumerate(note['segments']):
                p0, p1 = pitches[k]
                a0 = round(axis_of(s, locs[k]))
                dc = cross_of(sg['end']) - cross_of(sg['start'])
                ok_k = abs(dc - (p1 - p0) * 14) <= 1.01 and abs(time_of(sg['start']) - (a0 + (sg['width'] - 1) / 2)) <= 1.01
                if not sg['ellipse']:
                    a1 = round(axis_of(s, locs[k + 1]))
                    ok_k = ok_k and abs(time_of(sg['end']) - (a1 - sg['width'] + (sg['width'] - 1) / 2)) <= 1.01
                ok = ok and ok_k
                d.append(f'{name}{k}:{ok_k}')
        check(2, f'{o}: each segment\'s end circles: at its start / end (inset by the radius), at post / next pre pitch', ok, ' '.join(d))
        check(2, f'{o}: a flat note: one capsule, no pre → post capsule', len(A['segments']) == 1 and not A['transitions']
              and A['segments'][0]['start'][1 if hz else 0] == A['segments'][0]['end'][1 if hz else 0])
        tb = B['transitions']
        sg = B['segments']
        ok = len(tb) == 3 and tb[0][1] == sg[0]['start'] and tb[1] == [sg[0]['end'], sg[1]['start']] \
            and tb[2] == [sg[1]['end'], sg[2]['start']] and time_of(tb[0][0]) < time_of(sg[0]['start']) \
            and abs(cross_of(tb[0][0]) - cross_of(sg[0]['start']) - (60 - 62) * 14) <= 1.01
        check(2, f'{o}: B: pre → post capsules across the first point (from the pre-pitch before it) and between the segments at both inner points',
              ok, str(tb))
        check(2, f'{o}: C: segments shorter than wide are ellipses, and get no pre → post capsules',
              all(x['ellipse'] for x in C['segments']) and not C['transitions'], str([(x['length'], x['width']) for x in C['segments']]))
        s.snapshot('notes')

    # 3. Hover, handles and cursor.
    if run(3):
        def hover(p):
            s.input(f'move {P(view_to_screen(s, p))}')
            ns = notes_of(s)
            return [x['hoveredSegment'] for x in ns], s.state['waveforms']['main']['cursor']

        h = A['segments'][0]['handles']
        hs, cur = hover(h[1])
        check(3, f'{o}: on A\'s middle handle: A segment 0 hovered, 3 handles, open hand',
              hs == [0, None, None, None] and len(notes_of(s)[0]['segments'][0]['handles']) == 3 and cur == 'openHand', f'{hs} {cur}')
        s.snapshot('hover_a')
        q = ((h[0][0] + h[1][0]) / 2, (h[0][1] + h[1][1]) / 2)
        hs, cur = hover(q)
        check(3, f'{o}: on A between two handles: hovered, arrow', hs[0] == 0 and cur == 'arrow', f'{hs} {cur}')
        for x in h[::2]:
            hs, cur = hover(x)
            check(3, f'{o}: on A\'s end handle at {x}: open hand', cur == 'openHand', cur)
        mid = B['segments'][1]['handles'][1]
        hs, cur = hover(mid)
        check(3, f'{o}: on B\'s middle segment: only that segment is hovered (its 3 handles)', hs == [None, 1, None, None]
              and cur == 'openHand', f'{hs} {cur}')
        s.snapshot('hover_b')
        m = D['segments'][0]
        hs, cur = hover(m['handles'][0] if m['handles'] else m['start'])
        check(3, f'{o}: D ({m["length"]:.0f} pt long, {m["width"]:.0f} wide): only the middle handle',
              hs == [None, None, None, 0] and len(m['handles']) == 1 and cur == 'openHand', f'{hs} {m["handles"]}')
        c0 = C['segments'][0]
        eb = c0['ellipseBox']
        hs, cur = hover((eb[0] + eb[2] / 2, eb[1] + eb[3] / 2))
        check(3, f'{o}: C (ellipse): hovered, no handles, arrow', hs[2] is not None and not c0['handles'] and cur == 'arrow', f'{hs} {cur}')
        far = A['segments'][0]['handles'][1]
        hs, cur = hover((far[0], far[1] - 60) if hz else (far[0] - 60, far[1]))
        check(3, f'{o}: away from the notes: nothing hovered, arrow', hs == [None] * 4 and cur == 'arrow', f'{hs} {cur}')
        s.command('view 4.5,8.5'); s.dump()
        s.input(f'move {P(view_to_screen(s, notes_of(s)[1]["segments"][0]["handles"][1]))}')
        s.snapshot('closeup_b')
    # 4. Over a note: no hover cell; the note's harmonic copies instead; a click places nothing.
    if run(4):
        s.command('view 2,10' if hz else 'view 2,12'); s.dump()
        A = notes_of(s)[0]
        h = A['segments'][0]['handles'][1]
        q = (h[0] + 20, h[1]) if hz else (h[0], h[1] + 20)  # on the capsule, off the handle
        s.command('harmonics 3')
        s.input(f'move {P(view_to_screen(s, q))}')
        main = s.state['waveforms']['main']
        cp = main['noteHarmonics']
        r = A['rect']
        ok = main['hoverCell'] is None and len(cp) == 2
        if ok:
            for c, i in zip(cp, (2, 3)):
                d = 12 * math.log2(i) * 14
                ok = ok and (abs((r[1] + 0.5 - d) - c[1]) <= 2 and abs(c[0] - (r[0] + 0.5)) <= 2 if hz
                             else abs((r[0] + 0.5 + d) - c[0]) <= 2 and abs(c[1] - (r[1] + 0.5)) <= 2)
        check(4, f'{o}: over a note with harmonics 3: no hover cell, 2 copies of the note 12 and 19.02 semitones higher',
              ok, f'{main["hoverCell"]} {cp} rect {r}')
        s.snapshot('note_harmonics')
        before = len(notes_of(s))
        s.input(f'click {P(view_to_screen(s, q))}')
        check(4, f'{o}: a click on a note places nothing', len(notes_of(s)) == before)
        far = (q[0], q[1] - 60) if hz else (q[0] - 60, q[1])
        s.input(f'move {P(view_to_screen(s, far))}')
        main = s.state['waveforms']['main']
        check(4, f'{o}: away from the notes: the hover cell again, no note copies',
              main['hoverCell'] is not None and main['noteHarmonics'] == [] and len(main['hoverCell']['harmonicRects']) == 2)
        s.command('harmonics 1')
    s.quit()

print(f'{sum(results)}/{len(results)} passed')
