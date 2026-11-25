"""Milestone 13 checks (in progress): grid lines only while the Grid panel is open, spectrogram
presses only pan, the hover grid cell.
Run from prototype/: python3 verify/verify_m13.py

Needs Accessibility and Screen Recording permission for the terminal. Don't touch the mouse or
keyboard while it runs. Screenshots: verify/out/m13/*.png. ONLY=2,4 runs selected criteria.
"""
import atexit, json, math, os, subprocess, sys
import numpy as np

sys.path.insert(0, os.path.dirname(__file__))
import m3session  # noqa: E402
import m4util  # noqa: E402
from m4util import Session, build_driver, check, results, DOMAIN  # noqa: E402
from gen_test_audio_m2 import write_float_wav  # noqa: E402

OUT = 'verify/out/m13'
os.makedirs(OUT, exist_ok=True)
m3session.OUT = m4util.OUT = OUT
DRIVER = m3session.DRIVER = f'{OUT}/inputdriver'
AUDIO = os.path.abspath(f'{OUT}/audio')
ONLY = set(os.environ.get('ONLY', '').split(',')) - {''}
ORIENTATIONS = ('horizontal', 'vertical')
SR = 44100
KEYS = ['timeOrientation', 'followPlayhead', 'mainPaneMode', 'showBeats', 'gridKind', 'gridStraight']
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
rng = np.random.default_rng(13)
AUDIO_PATH = f'{AUDIO}/notes.wav'
t = np.arange(SR * 20) / SR
sig = 0.2 * np.sin(2 * np.pi * 440 * t) + 0.005 * rng.standard_normal(len(t))
write_float_wav(AUDIO_PATH, sig.astype(np.float32)[:, None], SR)
SIDE = AUDIO_PATH + '.beats.json'
# Beats every 0.5 s from 0.5 s, bar starts every 4 (4/4): 1/16 grid = 0.125 s.
json.dump([{'sample': int(round((0.5 + 0.5 * k) * SR)), 'firstBeat': 'auto'} for k in range(38)], open(SIDE, 'w'))


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
    """Screen point at time tm, `cross` fraction across the main pane (from the top / left)."""
    v0, v1 = s.view()
    return s.at('main', (tm - v0) / (v1 - v0), cross)


def lines_state(s):
    pb = s.state['playback']
    return pb['playhead'], pb['lastStart'], s.state['selection']


r = subprocess.run(['./build.sh'], capture_output=True, text=True)
check(1, 'builds', r.returncode == 0 and 'error' not in r.stdout + r.stderr, r.stdout[-400:] + r.stderr[-400:])
build_driver()
for k in KEYS:
    subprocess.run(['defaults', 'delete', DOMAIN, k], capture_output=True)

# 2. Grid lines only while the Grid panel is open; no checkbox.
if run(2):
    for o in ORIENTATIONS:
        s = session(f'{o}_grid', o)
        kinds = {l['kind'] for l in s.state['waveforms']['main']['editorLines']}
        tb = json.dumps(s.state['toolbar'])
        check(2, f'{o}: panel closed: bar and beat lines, no grid lines', kinds == {'bar', 'beat'}, str(kinds))
        check(2, f'{o}: no "Grid lines" checkbox in the toolbar', 'Grid lines' not in tb, tb[:300])
        s.snapshot('closed')
        s.command('gridpanel open'); s.dump()
        grid = [l for l in s.state['waveforms']['main']['editorLines'] if l['kind'] == 'grid']
        check(2, f'{o}: panel open: grid lines every 1/16 ({len(grid)})', len(grid) > 0 and s.state['grid']['panelOpen']
              and all(abs((l['time'] - 0.5) / 0.125 - round((l['time'] - 0.5) / 0.125)) < 1e-6 for l in grid))
        s.snapshot('open')
        s.command('gridpanel close'); s.dump()
        kinds = {l['kind'] for l in s.state['waveforms']['main']['editorLines']}
        check(2, f'{o}: panel closed again: no grid lines', 'grid' not in kinds, str(kinds))
        s.quit()

# 3. Spectrogram: presses don't touch the playhead, last start or selection; pan/zoom work.
if run(3):
    for o in ORIENTATIONS:
        s = session(f'{o}_mouse', o)
        s.command('select 3,4'); s.dump()
        before = lines_state(s)
        s.input(f'click {P(main_point(s, 5.0, 0.5))}')
        check(3, f'{o}: click: nothing changes', lines_state(s) == before, f'{lines_state(s)} vs {before}')
        s.input(f'drag {P(main_point(s, 5.0, 0.5))} {P(main_point(s, 6.0, 0.5))}')
        check(3, f'{o}: drag: no selection change', lines_state(s) == before, f'{lines_state(s)} vs {before}')
        s.input(f'click {P(main_point(s, 7.0, 0.5))} shift')
        check(3, f'{o}: shift-click: no extension', lines_state(s) == before, f'{lines_state(s)} vs {before}')
        s.input(f'drag {P(main_point(s, 3.0, 0.5))} {P(main_point(s, 3.6, 0.5))}')
        check(3, f'{o}: drag on the selection edge: no change', lines_state(s) == before, f'{lines_state(s)} vs {before}')
        s.input(f'drag {P(main_point(s, 2.0, 0.5))} {P(main_point(s, 2.8, 0.5))}')
        check(3, f'{o}: drag on the playhead: no change', lines_state(s) == before, f'{lines_state(s)} vs {before}')
        s.input(f'move {P(main_point(s, 3.0, 0.5))}')
        check(3, f'{o}: arrow cursor over a selection edge', s.state['waveforms']['main']['cursor'] == 'arrow',
              s.state['waveforms']['main']['cursor'])
        v0 = s.view()
        f0 = s.state['spectrogram']['freqView']['low']
        s.input(f'drag {P(main_point(s, 6.0, 0.5))} {P(main_point(s, 5.0, 0.4))} option')
        v1 = s.view()
        f1 = s.state['spectrogram']['freqView']['low']
        check(3, f'{o}: option-drag pans time and frequency', abs((v1[0] - v0[0]) - 1.0) < 0.05 and f1 != f0
              and lines_state(s) == before, f'{v0} → {v1}, low {f0} → {f1}')
        s.quit()
    s = session('waveform_mouse', 'horizontal', mode='waveform')
    s.input(f'click {P(main_point(s, 5.0, 0.5))}')
    check(3, 'waveform mode: a click still moves the playhead', abs(s.state['playback']['playhead'] - 5.0) < 0.02,
          str(s.state['playback']['playhead']))
    s.quit()


# 4. Hover cell.
def ref_span(beats, d, tm):
    """The spec's grid cell: one 1/d step from the bar start, cut at the next bar start; the
    pickup counted backwards from the first bar start, cut at the first beat."""
    t = [b['sample'] / SR for b in beats]
    starts = [i for i, b in enumerate(beats) if b['beatInBar'] == 1]
    if not (t[0] <= tm < t[-1]):
        return None
    segs = ([(0, starts[0], True)] if starts[0] > 0 else []) + \
        [(s0, (starts + [len(t) - 1])[k + 1], False) for k, s0 in enumerate(starts) if s0 < len(t) - 1]
    f, e, back = next(g for g in segs if t[g[0]] <= tm < t[g[1]])
    i = max(j for j in range(f, e) if t[j] <= tm)
    p = i + (tm - t[i]) / (t[i + 1] - t[i]) - f
    step = 4 / d
    n = e - f
    if back:
        k = math.floor((n - p) / step - 1e-9)
        a, b = max(n - (k + 1) * step, 0), n - k * step
    else:
        k = math.floor(p / step + 1e-9)
        a, b = k * step, min((k + 1) * step, n)

    def bt(x):
        j = min(int(x), len(t) - 2)
        return t[j] + (x - j) * (t[j + 1] - t[j])
    return bt(f + a), bt(f + b)


def probe(s, o, tm, cross, d, desc, expect=None):
    fr = s.state['screenFrames']['main']
    p = main_point(s, tm, cross)
    s.input(f'move {P(p)}')
    c = s.state['waveforms']['main']['hoverCell']
    local = fr['height'] - (p[1] - fr['y']) if o == 'horizontal' else p[0] - fr['x']
    v0, v1 = s.view()
    tp = v0 + (v1 - v0) * ((p[0] - fr['x']) / fr['width'] if o == 'horizontal' else (p[1] - fr['y']) / fr['height'])
    span = ref_span(s.state['beats'], d, tp)
    fv = s.state['spectrogram']['freqView']
    note = LOWEST + math.floor(fv['low'] + local / fv['pointsPerSemitone'])
    ok = c is not None and span is not None and abs(c['start'] - span[0]) < 1e-6 and abs(c['end'] - span[1]) < 1e-6 \
        and c['note'] == note and (expect is None or (abs(span[0] - expect[0]) < 1e-6 and abs(span[1] - expect[1]) < 1e-6))
    if ok:
        x, y, w, h = c['rect']
        ax = (p[0] - fr['x'], p[1] - fr['y'])
        ok = x - 1 <= ax[0] <= x + w + 1 and y - 1 <= ax[1] <= y + h + 1 and abs((h if o == 'horizontal' else w) - 14) <= 1
    check(4, f'{o}: 1/{d} at {tp:.3f} s ({desc}): cell {span and f"{span[0]:.3f}–{span[1]:.3f}"} s, MIDI {note}', ok, str(c))


def side(sigs):
    json.dump([dict({'sample': int(round((0.5 + 0.5 * k) * SR)), 'firstBeat': 'auto'},
                    **({'timeSignature': sigs[k]} if k in sigs else {})) for k in range(38)], open(SIDE, 'w'))


if run(4):
    for o in ORIENTATIONS:
        side({})
        s = session(f'{o}_hover', o)
        probe(s, o, 5.06, 0.5, 16, '4/4', (5.0, 5.125))
        probe(s, o, 7.49, 0.7, 16, '4/4', (7.375, 7.5))
        s.snapshot('cell16')
        ph0 = s.state['waveforms']['main']['dashPhase']
        import time as _t; _t.sleep(0.4); s.dump()
        ph1 = s.state['waveforms']['main']['dashPhase']
        check(4, f'{o}: the dashes move while a cell is shown ({ph0} → {ph1})',
              s.state['waveforms']['main']['dashesMoving'] and ph0 != ph1)
        s.command('grid straight 2')
        probe(s, o, 5.2, 0.3, 2, 'a half note: two beats', (4.5, 5.5))
        s.snapshot('cell2')
        s.command('grid straight 1')
        probe(s, o, 3.0, 0.45, 1, 'a whole note: the bar', (2.5, 4.5))
        s.command('grid triplet 6')
        probe(s, o, 3.0, 0.45, 6, 'triplet 1/6', (2.5 + 2 / 6, 2.5 + 4 / 6))
        s.command('grid straight 2')
        s.command('view 17,20'); s.dump()
        probe(s, o, 18.9, 0.45, 2, 'last bar: cut at the last beat', (18.5, 19.0))
        s.input(f'move {P(main_point(s, 19.5, 0.5))}')
        check(4, f'{o}: after the last beat: no cell', s.state['waveforms']['main']['hoverCell'] is None,
              str(s.state['waveforms']['main']['hoverCell']))
        s.command('view 0,10'); s.dump()
        s.input(f'move {P(main_point(s, 0.2, 0.5))}')
        check(4, f'{o}: before the first beat: no cell', s.state['waveforms']['main']['hoverCell'] is None,
              str(s.state['waveforms']['main']['hoverCell']))
        s.input(f'move {P(s.at("navigator", 0.5))}')
        check(4, f'{o}: pointer off the spectrogram: no cell', s.state['waveforms']['main']['hoverCell'] is None)
        _t.sleep(0.3); s.dump()
        check(4, f'{o}: no cell, no grid lines: the dash timer stops', not s.state['waveforms']['main']['dashesMoving'])
        s.quit()
        # 3/4 on beat 2 (1.5 s): 2 pickup beats, then bars of 1.5 s.
        side({2: '3/4'})
        s = session(f'{o}_hover34', o)
        s.command('grid straight 2')
        probe(s, o, 2.0, 0.5, 2, '3/4: first half note', (1.5, 2.5))
        probe(s, o, 2.7, 0.5, 2, '3/4: second half note cut at the bar line', (2.5, 3.0))
        s.command('grid triplet 3')
        s.command('view 0,3'); s.dump()
        probe(s, o, 1.2, 0.5, 3, 'pickup: counted back from bar 1', (1.5 - 2 / 3, 1.5))
        probe(s, o, 0.6, 0.5, 3, 'pickup: cut at the first beat', (0.5, 1.5 - 2 / 3))
        s.command('gridpanel open')
        s.command('grid straight 8'); s.dump()
        g8 = [l['time'] for l in s.state['waveforms']['main']['editorLines'] if l['kind'] == 'grid' and l['time'] < 1.5]
        check(4, f'{o}: 1/8 grid lines also in the pickup', g8 == [0.75, 1.25], str(g8))
        s.snapshot('pickup_lines')
        s.command('gridpanel close')
        s.quit()
    s = session('waveform_hover', 'horizontal', mode='waveform')
    s.input(f'move {P(main_point(s, 5.06, 0.5))}')
    check(4, 'waveform mode: no cell', s.state['waveforms']['main']['hoverCell'] is None)
    s.quit()

# 5. Placing notes: a click in a hover cell stores a note at the cell's geometry.
if run(5):
    for o in ORIENTATIONS:
        side({})
        s = session(f'{o}_notes', o)
        s.command('grid straight 8')
        placed = []
        for tm, cross in [(5.1, 0.5), (5.3, 0.5), (5.1, 0.5 - 14 / 700 if o == 'horizontal' else 0.5 + 14 / 1000),
                          (6.6, 0.4)]:
            p = main_point(s, tm, cross)
            s.input(f'move {P(p)}')
            cell = s.state['waveforms']['main']['hoverCell']
            s.input(f'click {P(p)}')
            notes = s.state['waveforms']['main']['notes']
            exp = {'midi': cell['note'], 'start': round(cell['start'] * SR), 'end': round(cell['end'] * SR)}
            got = notes[-1] if notes else None
            ok = got is not None and len(notes) == len(placed) + 1 and \
                all(got[k] == exp[k] for k in exp) and lines_state(s) == lines_state(s)
            check(5, f'{o}: click at {tm} s: note MIDI {exp["midi"]} {exp["start"] / SR:.3f}–{exp["end"] / SR:.3f} s',
                  ok, f'{got} vs {exp}')
            placed.append(exp)
        s.input(f'click {P(main_point(s, 5.1, 0.5))}')
        check(5, f'{o}: a second click on the same note adds nothing', len(s.state['waveforms']['main']['notes']) == 4)
        s.input(f'drag {P(main_point(s, 7.1, 0.5))} {P(main_point(s, 7.6, 0.5))}')
        check(5, f'{o}: a drag places no note', len(s.state['waveforms']['main']['notes']) == 4)
        s.input(f'click {P(main_point(s, 7.1, 0.5))} option')
        check(5, f'{o}: option-click places no note', len(s.state['waveforms']['main']['notes']) == 4)
        rects = [n['rect'] for n in s.state['waveforms']['main']['notes']]

        def overlap(a, b):
            return a[0] < b[0] + b[2] and b[0] < a[0] + a[2] and a[1] < b[1] + b[3] and b[1] < a[1] + a[3]
        touch_t = rects[0][0] + rects[0][2] == rects[1][0] if o == 'horizontal' else rects[0][1] + rects[0][3] == rects[1][1]
        touch_p = (rects[2][1] + rects[2][3] == rects[0][1]) if o == 'horizontal' else (rects[0][0] + rects[0][2] == rects[2][0])
        check(5, f'{o}: neighbouring notes in time and pitch touch without overlapping',
              touch_t and touch_p and not any(overlap(rects[i], rects[j]) for i in range(4) for j in range(i + 1, 4)),
              str(rects[:3]))
        s.input(f'move {P(main_point(s, 8.5, 0.6))}')
        s.snapshot('placed')
        s.quit()

print(f'{sum(results)}/{len(results)} passed')
