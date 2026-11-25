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
def expected_cell(s, tm, local_cross):
    """Bracketing 1/16 grid times (bars from 0.5 s to the last bar start, beats to the last beat) and the note."""
    lines = sorted(set([0.5 + 0.5 * k for k in range(38)]
                       + [0.5 + 0.125 * k for k in range(int((0.5 + 0.5 * 36 - 0.5) / 0.125) + 1)]))
    lo = max(x for x in lines if x <= tm + 1e-9)
    hi = min(x for x in lines if x > tm + 1e-9)
    fv = s.state['spectrogram']['freqView']
    st = fv['low'] + local_cross / fv['pointsPerSemitone']
    return lo, hi, LOWEST + math.floor(st)


if run(4):
    for o in ORIENTATIONS:
        s = session(f'{o}_hover', o)
        fr = s.state['screenFrames']['main']
        for tm, cross in [(5.06, 0.5), (5.2, 0.3), (7.49, 0.7), (1.6, 0.45)]:
            p = main_point(s, tm, cross)
            s.input(f'move {P(p)}')
            c = s.state['waveforms']['main']['hoverCell']
            if o == 'horizontal':
                local = fr['height'] - (p[1] - fr['y'])
            else:
                local = p[0] - fr['x']
            v0, v1 = s.view()
            tp = v0 + (v1 - v0) * ((p[0] - fr['x']) / fr['width'] if o == 'horizontal' else (p[1] - fr['y']) / fr['height'])
            lo, hi, note = expected_cell(s, tp, local)
            ok = c is not None and abs(c['start'] - lo) < 1e-6 and abs(c['end'] - hi) < 1e-6 and c['note'] == note
            if ok:
                x, y, w, h = c['rect']
                ax = (p[0] - fr['x'], p[1] - fr['y'])
                inside = x - 1 <= ax[0] <= x + w + 1 and y - 1 <= ax[1] <= y + h + 1
                ok = inside and abs((h if o == 'horizontal' else w) - 14) <= 1
            check(4, f'{o}: at {tp:.3f} s: cell {lo:.3f}–{hi:.3f} s, MIDI {note}', ok, str(c))
            if tm == 5.06:
                s.snapshot('cell')
        s.input(f'move {P(main_point(s, 0.2, 0.5))}')
        check(4, f'{o}: before the first beat: no cell', s.state['waveforms']['main']['hoverCell'] is None,
              str(s.state['waveforms']['main']['hoverCell']))
        s.input(f'move {P(s.at("navigator", 0.5))}')
        check(4, f'{o}: pointer off the spectrogram: no cell', s.state['waveforms']['main']['hoverCell'] is None)
        s.quit()
    s = session('waveform_hover', 'horizontal', mode='waveform')
    s.input(f'move {P(main_point(s, 5.06, 0.5))}')
    check(4, 'waveform mode: no cell', s.state['waveforms']['main']['hoverCell'] is None)
    s.quit()

print(f'{sum(results)}/{len(results)} passed')
