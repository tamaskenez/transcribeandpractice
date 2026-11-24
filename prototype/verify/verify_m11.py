"""Checks milestone 11 acceptance criteria (editor grid: bar, beat and grid lines; Grid control).
Run from prototype/: python3 verify/verify_m11.py

Needs Accessibility and Screen Recording permission for the terminal. Don't touch the mouse or
keyboard while it runs. Screenshots: verify/out/m11/*.png.
Only milestone 11 is checked. ONLY=2,5 runs selected criteria.
"""
import atexit, json, math, os, subprocess, sys, time
from fractions import Fraction
import numpy as np

sys.path.insert(0, os.path.dirname(__file__))
import m3session  # noqa: E402
import m4util  # noqa: E402
from m4util import Session, build_driver, check, results, DOMAIN  # noqa: E402
from gen_test_audio_m2 import write_float_wav  # noqa: E402

OUT = 'verify/out/m11'
os.makedirs(OUT, exist_ok=True)
m3session.OUT = m4util.OUT = OUT
DRIVER = m3session.DRIVER = f'{OUT}/inputdriver'
AUDIO = os.path.abspath(f'{OUT}/audio')
ONLY = set(os.environ.get('ONLY', '').split(',')) - {''}
ORIENTATIONS = ('horizontal', 'vertical')
MIN_SPACING = 6.0
BEAT_NOTE = Fraction(1, 4)
KEYS = ['timeOrientation', 'followPlayhead', 'mainPaneMode', 'spectrogramWindowMs', 'showBeats',
        'gridLinesShown', 'gridKind', 'gridStraight', 'gridTriplet', 'gridTuplet']


def run(c):
    return not ONLY or str(c) in ONLY


def kill_leftovers():
    subprocess.run(['pkill', '-f', '^build/TranscribeAndPractice[.]app/'], capture_output=True)


# Remember the user's settings (with their types) and restore them afterwards.
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


def reset_defaults():
    for k in KEYS:
        subprocess.run(['defaults', 'delete', DOMAIN, k], capture_output=True)


kill_leftovers()
atexit.register(kill_leftovers)
atexit.register(restore_defaults)

# --- Test audio with beat sidecars (the full beat list, as the app would have computed it) ---
os.makedirs(AUDIO, exist_ok=True)
rng = np.random.default_rng(11)
FILES = {}


def make(name, dur, sr, times, downbeats, sig=None):
    """times: beat times (s); downbeats: set of indices; sig: time signature on the first beat."""
    x = (0.01 * rng.standard_normal(int(dur * sr))).astype(np.float32)
    for t in times:  # a click per beat
        i = int(t * sr)
        x[i:i + int(0.02 * sr)] += np.float32(0.4)
    path = f'{AUDIO}/{name}.wav'
    write_float_wav(path, x[:, None], sr)
    samples = [int(round(t * sr)) for t in times]
    beats = []
    for i, s in enumerate(samples):
        b = {'sample': s, 'source': 'placed' if i < 3 else 'computed',
             'firstBeat': ('placed' if i == min(downbeats) else 'computed') if i in downbeats else 'no'}
        if i == 0 and sig:
            b['timeSignature'] = sig
        beats.append(b)
    json.dump(beats, open(path + '.beats.json', 'w'))
    FILES[name] = (path, sr, samples, [i in downbeats for i in range(len(samples))], dur)


def jittered(start, interval, count, jitter=0.0, drift=0.0):
    out, t = [], start
    for k in range(count):
        out.append(t + (rng.uniform(-jitter, jitter) if 0 < k < count - 1 else 0))
        t += interval * (1 + drift * k)
    return out


# 4/4 with a pickup (beat 0) and uneven spacing; downbeats every 4 from beat 1.
t = jittered(0.3, 0.5, 38, jitter=0.04)
make('fourfour', 20.0, 44100, t, {i for i in range(1, len(t), 4)}, '4/4')
# 3/4 with tempo drift.
t = jittered(0.2, 0.55, 30, drift=0.004)
make('threefour', 20.0, 44100, t, set(range(0, len(t), 3)), '3/4')
# 6/8 and 5/8: 3 beats per bar.
t = jittered(0.25, 0.45, 40, jitter=0.02)
make('sixeight', 20.0, 44100, t, set(range(0, len(t), 3)), '6/8')
t = jittered(0.25, 0.4, 45, jitter=0.02)
make('fiveeight', 20.0, 44100, t, set(range(0, len(t), 3)), '5/8')
# A change: three 4/4 bars, then 3/4.
t = jittered(0.2, 0.5, 34, jitter=0.02)
make('change', 20.0, 44100, t, {0, 4, 8} | set(range(12, len(t), 3)), '4/4')
# Beats without time signature: no downbeats.
t = jittered(0.4, 0.6, 30, jitter=0.03)
make('nosig', 20.0, 44100, t, set())
# Long (for crowding): 400 s, 4/4 at 120 BPM, 8 kHz.
t = [0.25 + 0.5 * k for k in range(798)]
make('long', 400.0, 8000, t, set(range(0, len(t), 4)), '4/4')
NOBEATS = f'{AUDIO}/nobeats.wav'
write_float_wav(NOBEATS, (0.01 * rng.standard_normal(44100 * 4)).astype(np.float32)[:, None], 44100)

# 1. Builds
r = subprocess.run(['./build.sh'], capture_output=True, text=True)
check(1, 'builds', r.returncode == 0 and 'error' not in r.stdout + r.stderr, r.stdout[-400:] + r.stderr[-400:])
build_driver()
reset_defaults()


# --- Reference ---
def ref_lines(samples, down, sr, n, start, end, length):
    times = [s / sr for s in samples]
    lines = [('bar' if down[i] else 'beat', tt) for i, tt in enumerate(times) if start <= tt <= end]
    if n:
        step = Fraction(1, n) / BEAT_NOTE
        bars = [i for i in range(len(samples)) if down[i]]
        for s, e in zip(bars, bars[1:]):
            if times[e] < start or times[s] > end:
                continue
            k = 1
            while True:
                pos = k * step
                if pos >= e - s:
                    break
                k += 1
                if pos.denominator == 1:
                    continue
                whole = pos.numerator // pos.denominator
                frac = (pos.numerator - whole * pos.denominator) / pos.denominator
                a, b = times[s + whole], times[s + whole + 1]
                tt = a + frac * (b - a)
                if start <= tt <= end:
                    lines.append(('grid', tt))
    lines.sort(key=lambda x: x[1])

    def axis(tt):
        return (tt - start) / (end - start) * length

    def crowded(kinds):
        a = [axis(tt) for k, tt in lines if k in kinds]
        return any(q - p < MIN_SPACING for p, q in zip(a, a[1:]))
    shown = {'bar', 'beat', 'grid'}
    if crowded({'bar', 'beat', 'grid'}):
        shown.discard('grid')
    if crowded({'bar', 'beat'}):
        shown.discard('beat')
    if crowded({'bar'}):
        shown.discard('bar')
    return [(k, tt, axis(tt)) for k, tt in lines if k in shown]


def pane_len(s, pane='main'):
    w = s.state['waveforms'][pane]['size']
    return w['width'] if s.state['orientation'] == 'horizontal' else w['height']


def compare(s, name, n):
    path, sr, samples, down, dur = FILES[name]
    v = s.state['view']
    ref = ref_lines(samples, down, sr, n, v['start'], v['end'], pane_len(s))
    got = [(l['kind'], l['time'], l['axis']) for l in s.state['waveforms']['main']['editorLines']]
    if len(got) != len(ref):
        return False, f'{len(got)} lines vs reference {len(ref)}', ref
    bad = [(g, r) for g, r in zip(got, ref) if g[0] != r[0] or abs(g[1] - r[1]) > 1e-6 or abs(g[2] - r[2]) > 0.01]
    return not bad, f'{len(bad)} differ; first {bad[:2]}', ref


def session(name, opens, orientation, mode='spectrogram'):
    s = Session(name, opens=opens, orientation=orientation)
    s.command('resize 1000,700')
    s.command('follow off')
    s.command(f'mode {mode}')
    s.command('gridlines on')
    s.dump()
    return s


GRIDS = [('straight', 1), ('straight', 4), ('straight', 8), ('straight', 16),
         ('triplet', 3), ('triplet', 12), ('tuplet', 5), ('tuplet', 7)]

# 2. Line positions
if run(2):
    for o in ORIENTATIONS:
        for name in ('fourfour', 'threefour', 'sixeight', 'fiveeight', 'change', 'nosig'):
            s = session(f'{o}_{name}', [FILES[name][0]], o)
            for kind, n in GRIDS:
                s.command(f'grid {kind} {n}')
                total = {'bar': 0, 'beat': 0, 'grid': 0}
                fails = []
                for w0 in range(0, 20, 4):
                    s.command(f'view {w0},{w0 + 4}')
                    s.dump()
                    ok, detail, ref = compare(s, name, n)
                    for k, _, _ in ref:
                        total[k] += 1
                    if not ok:
                        fails.append(f'{w0}–{w0 + 4} s: {detail}')
                check(2, f'{o} {name} {kind} 1/{n}: lines match the reference over the file ({total})',
                      not fails and (total['grid'] > 0) == (name != 'nosig' and 4 % n != 0),  # 1/1, 1/4: on beats only
                      '; '.join(fails[:2]))
            # The grid stays between the first and the last downbeat, never on a beat.
            path, sr, samples, down, dur = FILES[name]
            s.command('grid straight 16')
            first_last = [samples[i] / sr for i in range(len(samples)) if down[i]]
            grid_times = []
            for w0 in range(0, 20, 2):
                s.command(f'view {w0},{w0 + 2}')
                s.dump()
                grid_times += [l['time'] for l in s.state['waveforms']['main']['editorLines'] if l['kind'] == 'grid']
            beat_times = {round(x / sr, 9) for x in samples}
            if first_last:
                ok = all(first_last[0] < g < first_last[-1] for g in grid_times) and not any(round(g, 9) in beat_times for g in grid_times)
                check(2, f'{o} {name}: {len(grid_times)} grid lines (1/16), all between the first and last downbeat, none on a beat', ok and grid_times)
            else:
                check(2, f'{o} {name}: no downbeats, so no grid lines and no bar lines', not grid_times)
            s.quit()

# 3. Where lines appear
if run(3):
    for o in ORIENTATIONS:
        s = session(f'{o}_where', [FILES['fourfour'][0]], o)
        s.command('grid straight 16')
        s.command('view 2,6')
        s.dump()

        def kinds(pane='main'):
            return {l['kind'] for l in s.state['waveforms'][pane]['editorLines']}
        check(3, f'{o}: spectrogram mode, checkbox on: bar, beat and grid lines', kinds() == {'bar', 'beat', 'grid'}, str(kinds()))
        s.command('gridlines off'); s.dump()
        check(3, f'{o}: checkbox off: bar and beat lines only', kinds() == {'bar', 'beat'}, str(kinds()))
        s.command('gridlines on'); s.command('mode waveform'); s.dump()
        check(3, f'{o}: waveform mode: bar and beat lines only', kinds() == {'bar', 'beat'}, str(kinds()))
        s.command('beats off'); s.dump()
        check(3, f'{o}: waveform mode with Show Beats off: still bar and beat lines', kinds() == {'bar', 'beat'}, str(kinds()))
        s.command('mode spectrogram'); s.dump()
        check(3, f'{o}: spectrogram mode with Show Beats off: all three kinds', kinds() == {'bar', 'beat', 'grid'}, str(kinds()))
        check(3, f'{o}: no lines in the navigator', not s.state['waveforms']['navigator']['editorLines'])
        s.command('beats on')
        s.command(f'open {NOBEATS}'); s.dump()
        check(3, f'{o}: a file without beats: no lines', not s.state['waveforms']['main']['editorLines'])
        s.quit()

# 4. Crowding
if run(4):
    for o in ORIENTATIONS:
        s = session(f'{o}_crowd', [FILES['long'][0]], o)
        s.command('grid straight 16')
        seen = set()
        fails = []
        for length in (2, 4, 8, 12, 16, 24, 32, 48, 64, 100, 150, 200, 300, 400.1):
            s.command(f'view 0,{length}')
            s.dump()
            ok, detail, ref = compare(s, 'long', 16)
            got_kinds = frozenset(l['kind'] for l in s.state['waveforms']['main']['editorLines'])
            seen.add(got_kinds)
            if not ok:
                fails.append(f'{length} s: {detail}')
        check(4, f'{o}: at every zoom the shown kinds and lines match the reference', not fails, '; '.join(fails[:2]))
        order = [frozenset({'bar', 'beat', 'grid'}), frozenset({'bar', 'beat'}), frozenset({'bar'}), frozenset()]
        check(4, f'{o}: zooming out hides grid, then beat, then bar lines', all(k in seen for k in order),
              str(sorted(map(sorted, seen))))
        s.quit()


# 5. Grid control
def ax(s, *lines):
    r = subprocess.run([DRIVER], input='\n'.join(lines) + '\n', capture_output=True, text=True)
    time.sleep(0.3)
    s.dump()
    return r.stdout.split()


if run(5):
    reset_defaults()
    s = session('control', [FILES['fourfour'][0]], 'horizontal', mode='waveform')
    pid = s.proc.pid
    out = ax(s, f'enabled {pid} Grid lines', f'enabled {pid} Grid')
    check(5, 'waveform mode: no Grid lines checkbox and no Grid button', out == ['notfound', 'notfound'], str(out))
    s.command('mode spectrogram')
    out = ax(s, f'enabled {pid} Grid lines', f'enabled {pid} Grid')
    g = s.state['grid']
    check(5, f'spectrogram mode: checkbox and button present; defaults on, straight 1/16 (triplet 1/12, tuplet 1/5)',
          out == ['true', 'true'] and g == {'linesShown': True, 'kind': 'straight', 'straight': 16, 'triplet': 12, 'tuplet': 5, 'n': 16},
          f'{out} {g}')
    ax(s, f'press {pid} Grid lines')
    check(5, 'pressing the checkbox turns the grid lines off', s.state['grid']['linesShown'] is False)
    ax(s, f'press {pid} Grid lines')
    check(5, 'pressing it again turns them on', s.state['grid']['linesShown'] is True)
    out = ax(s, f'press {pid} Grid', 'sleep 400', f'press {pid} 1/8')
    check(5, 'panel: 1/8 in the straight list selects straight 1/8', s.state['grid']['n'] == 8 and s.state['grid']['kind'] == 'straight', f'{out} {s.state["grid"]}')
    # Screenshot of the open panel (screen region around the window's top).
    w = s.state['screenFrames']['window']
    subprocess.run(['screencapture', '-x', '-R', f'{int(w["x"])},{int(w["y"])},{int(w["width"])},420', f'{OUT}/panel_straight.png'])
    out = ax(s, f'press {pid} Triplet')
    check(5, 'panel: Triplet switches to the triplet value (1/12)', s.state['grid']['kind'] == 'triplet' and s.state['grid']['n'] == 12, f'{out} {s.state["grid"]}')
    out = ax(s, f'press {pid} 1/24')
    check(5, 'panel: 1/24 selects triplet 1/24', s.state['grid']['n'] == 24, f'{out} {s.state["grid"]}')
    subprocess.run(['screencapture', '-x', '-R', f'{int(w["x"])},{int(w["y"])},{int(w["width"])},420', f'{OUT}/panel_triplet.png'])
    out = ax(s, f'press {pid} Straight')
    check(5, 'panel: Straight returns to straight 1/8 (each kind keeps its value)', s.state['grid']['kind'] == 'straight' and s.state['grid']['n'] == 8, f'{out} {s.state["grid"]}')
    out = ax(s, f'press {pid} Tuplet', 'sleep 300', f'focus {pid} Tuplet value', 'key a cmd', 'type 9', 'sleep 200')
    check(5, 'panel: typing 9 in the tuplet field selects tuplet 1/9', s.state['grid']['kind'] == 'tuplet' and s.state['grid']['n'] == 9, f'{out} {s.state["grid"]}')
    subprocess.run(['screencapture', '-x', '-R', f'{int(w["x"])},{int(w["y"])},{int(w["width"])},420', f'{OUT}/panel_tuplet.png'])
    # The field applies every keystroke: typing "65" passes through the valid "6".
    for typed, expect in (('0', 9), ('65', 6), ('x', 6)):
        out = ax(s, 'key a cmd', f'type {typed}', 'sleep 200')
        check(5, f'panel: typing "{typed}" leaves the last valid value (1/{expect})', s.state['grid']['n'] == expect, f'{out} {s.state["grid"]}')
    out = ax(s, 'key a cmd', 'type 64', 'sleep 200')
    check(5, 'panel: 64 is accepted', s.state['grid']['n'] == 64, f'{out} {s.state["grid"]}')
    ax(s, 'key escape')
    ax(s, f'press {pid} Grid lines')
    final = dict(s.state['grid'])
    s.quit()
    s = Session('control_relaunch', opens=[FILES['fourfour'][0]], orientation='horizontal')
    g = s.state['grid']
    check(5, f'the settings survive a relaunch ({g})', g == final and g == {'linesShown': False, 'kind': 'tuplet', 'straight': 8,
                                                                          'triplet': 24, 'tuplet': 64, 'n': 64}, f'{g} vs {final}')
    s.quit()
    reset_defaults()

# 6. Appearance
if run(6):
    for o in ORIENTATIONS:
        s = session(f'{o}_look', [FILES['fourfour'][0]], o)
        s.command('grid straight 16')
        s.command('view 1,5')
        time.sleep(1.5)
        s.snapshot('spectrogram_16')
        s.command('grid triplet 12')
        time.sleep(0.5)
        s.snapshot('spectrogram_t12')
        s.command('mode waveform')
        s.snapshot('waveform')
        s.command('mode spectrogram')
        s.command('view -0.05,20.05')
        time.sleep(1.5)
        s.snapshot('spectrogram_full')
        s.quit()
    print(f'Screenshots for the human check: {OUT}/*_look_*.png, {OUT}/panel_*.png')

print(f'\n{sum(results)} of {len(results)} checks passed')
sys.exit(0 if all(results) else 1)
