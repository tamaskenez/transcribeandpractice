"""Checks milestone 6 acceptance criteria (beat markers). Run from prototype/: python3 verify/verify_m6.py

Plays audio briefly (criterion 1's earlier scripts). Needs Accessibility and Screen Recording
permission for the terminal. Don't touch the mouse or keyboard while it runs.
Screenshots: verify/out/m6/*.png. Set SKIP_EARLIER=1 to skip criterion 1 (the earlier scripts).
"""
import atexit, json, math, os, struct, subprocess, sys, time
import numpy as np

sys.path.insert(0, os.path.dirname(__file__))
import m3session  # noqa: E402
import m4util  # noqa: E402
from m4util import Session, build_driver, check, P, pb, results, SR, DOMAIN, BIN  # noqa: E402
from gen_test_audio_m2 import write_float_wav  # noqa: E402

OUT = 'verify/out/m6'
m3session.OUT = m4util.OUT = OUT
m3session.DRIVER = f'{OUT}/inputdriver'
AUDIO = os.path.abspath(f'{OUT}/audio')
NOISE = f'{AUDIO}/noise.wav'
LONG_SR = 8000
FRAMES = 441000  # the 10 s noise file at 44.1 kHz
GAP = 30


def kill_leftovers():
    subprocess.run(['pkill', '-f', '^build/TranscribeAndPractice[.]app/'], capture_output=True)


kill_leftovers()
atexit.register(kill_leftovers)

# 1. Earlier milestones
if os.environ.get('SKIP_EARLIER'):
    subprocess.run(['./build.sh'], check=True, capture_output=True)
else:
    # verify_m5 runs verify_m4 (→ m3, m2, m1, the builds) and verify_m4_review
    r = subprocess.run([sys.executable, 'verify/verify_m5.py'], capture_output=True, text=True)
    fails = [l for l in r.stdout.splitlines() if l.startswith('FAIL')]
    check(1, 'verify_m5.py passes (with verify_m1 … m4, m4_review)', r.returncode == 0 and not fails,
          '\n'.join(fails) or r.stdout[-400:] + r.stderr[-400:])
    kill_leftovers()

os.makedirs(AUDIO, exist_ok=True)
subprocess.run([sys.executable, 'verify/gen_test_audio_m4.py', AUDIO], check=True, capture_output=True)
LONG = f'{AUDIO}/dense.wav'
if not os.path.exists(LONG):
    write_float_wav(LONG, np.zeros((12 * 60 * LONG_SR, 1), np.float32), LONG_SR)
build_driver()


def beat(t, source, first, ts=None, sr=SR):
    d = {'sample': int(round(t * sr)), 'source': source, 'firstBeat': first}
    if ts:
        d['timeSignature'] = ts
    return d


# The main test list: a pickup (placed, computed), then bars at 120 BPM (0.5 s per beat).
MAIN = [beat(0.5, 'placed', 'no'), beat(1.0, 'computed', 'no')]
bar_kinds = [('placed', 'placed', '4/4'), ('computed', 'computed', None), ('placed', 'computed', None),
             ('computed', 'placed', '3/4'), ('placed', 'placed', None)]
bar_starts = [1.5, 3.5, 5.5, 7.5, 9.0]
bar_len = [4, 4, 4, 3, 2]
for (src, first, ts), t0, n in zip(bar_kinds, bar_starts, bar_len):
    MAIN.append(beat(t0, src, first, ts))
    for j in range(1, n):
        MAIN.append(beat(t0 + 0.5 * j, 'computed' if j % 2 else 'placed', 'no'))
# The dense list: 240 BPM over the 12-minute file, bars of 4.
DENSE = [beat(i * 0.25, 'computed' if i % 2 else 'placed',
              ('placed' if i // 4 % 2 == 0 else 'computed') if i % 4 == 0 else 'no', '4/4' if i == 0 else None, LONG_SR)
         for i in range(12 * 60 * 4)]


def audio_with(name, sidecar, target=NOISE):
    """A link to the test audio named `name`.wav, with the sidecar text (None: no sidecar)."""
    p = f'{AUDIO}/{name}.wav'
    if os.path.lexists(p):
        os.remove(p)
    os.symlink(os.path.basename(target), p)
    side = p + '.beats.json'
    if os.path.exists(side):
        os.remove(side)
    if sidecar is not None:
        open(side, 'w').write(sidecar if isinstance(sidecar, str) else json.dumps(sidecar))
    return p


rev = list(reversed(MAIN))
rev[0], rev[3] = rev[3], rev[0]  # unsorted
MAIN_WAV = audio_with('main', rev)
NOBEATS = audio_with('nobeats', None)
DENSE_WAV = audio_with('dense_beats', DENSE, LONG)


def headless(opens, tag):
    path = os.path.abspath(f'{OUT}/{tag}.json')
    if os.path.exists(path):
        os.remove(path)
    subprocess.run([BIN] + [f'--open={o}' for o in opens] + [f'--dump-state={path}', '--quit'],
                   capture_output=True, timeout=60)
    return json.load(open(path))


# 2. Sidecar loading
st = headless([MAIN_WAV], 'c2_main')
want = sorted(MAIN, key=lambda b: b['sample'])
got = [{k: v for k, v in b.items() if v is not None} for b in st['beats']]
check(2, f'valid unsorted sidecar: {len(got)} beats loaded sorted, every field as written, no alert',
      got == want and st['alertText'] is None, f'{got[:3]} want {want[:3]} alert {st["alertText"]}')
st = headless([NOBEATS], 'c2_none')
check(2, 'no sidecar: no beats, no alert', st['beats'] == [] and st['alertText'] is None, st['alertText'])
st = headless([audio_with('empty', [])], 'c2_empty')
check(2, 'empty array: no beats, no alert', st['beats'] == [] and st['alertText'] is None, st['alertText'])
good = beat(1.0, 'placed', 'placed')
bad = {
    'not_json': '[{"sample": 1,',
    'not_array': {'sample': 1},
    'not_objects': [1, 2],
    'missing': [{'sample': 100, 'source': 'placed'}],
    'source': [dict(good, source='guessed')],
    'firstbeat': [dict(good, firstBeat='yes')],
    'timesig': [dict(good, timeSignature='4/3')],
    'negative': [dict(good, sample=-1)],
    'range': [dict(good, sample=FRAMES)],
    'duplicate': [good, beat(0.5, 'placed', 'no'), dict(good, source='computed')],
}
for name, content in bad.items():
    p = audio_with(f'bad_{name}', content)
    st = headless([p], f'c2_bad_{name}')
    alert = st['alertText'] or ''
    check(2, f'invalid sidecar ({name}): alert “{alert}”, audio loaded, no beats',
          f'bad_{name}.wav.beats.json' in alert and st['loaded'] and st['loaded']['frames'] == FRAMES
          and st['beats'] == [] and st['alertTitle'] == 'Could not read beats', st)
st = headless([MAIN_WAV, NOBEATS], 'c2_replace1')
st2 = headless([NOBEATS, MAIN_WAV], 'c2_replace2')
check(2, 'opening another file replaces the beats (main → nobeats: none; nobeats → main: the main list)',
      st['beats'] == [] and len(st2['beats']) == len(MAIN), f'{len(st["beats"])} {len(st2["beats"])}')


# --- Reference rules (spec "Beat markers") ---
def beat_check(s, beats, sr):
    """Criteria 3/4 properties of the current dump. Returns (ok, detail, info)."""
    st = s.state
    r, horizontal = st['ruler'], st['orientation'] == 'horizontal'
    L = r['size']['width'] if horizontal else r['size']['height']
    if L != s.length('navigator'):
        return False, f'ruler length {L} != navigator {s.length("navigator")}', None
    if r['mode'] != 'beats' or r['ticks']:
        return False, f'mode {r["mode"]}, {len(r["ticks"])} time ticks', None
    vs, ve = s.view()
    d = st['loaded']['duration']
    lo, hi = max(vs, 0), min(ve, d)
    ax = lambda t: (t - vs) / (ve - vs) * L  # noqa: E731
    bars, n = [], 0
    for b in beats:
        if b['firstBeat'] != 'no':
            n += 1
            bars.append(n)
        else:
            bars.append(None)
    times = [b['sample'] / sr for b in beats]
    vis = [i for i, t in enumerate(times) if lo <= t <= hi]
    marks = r['marks']
    for m in marks:
        if abs(m['axis'] - ax(m['time'])) > 0.5:
            return False, f'mark {m["time"]} at {m["axis"]}, want {ax(m["time"])}', None
    numbered = {m['bar']: m for m in marks if m['bar'] is not None}
    down = [i for i in vis if bars[i]]
    # The bar number step: the smallest power of two that gives exactly the numbered bars.
    k = next((k for k in (2 ** j for j in range(16))
              if {bars[i] for i in down if (bars[i] - 1) % k == 0} == set(numbered)), None)
    if k is None:
        return False, f'numbered bars {sorted(numbered)[:8]} are not every k-th', None
    frames = [m['labelFrame'] for m in numbered.values() if m['labelFrame']]
    if not frames and numbered:
        return False, 'no label frames', None
    ext_of = lambda f: 3 + (f['width'] if horizontal else f['height'])  # noqa: E731
    per_digit = max((f['width'] / len(str(b)) for b, m in numbered.items() if (f := m['labelFrame'])), default=6)

    def ext(bar):
        m = numbered.get(bar)
        if m and m['labelFrame']:
            return ext_of(m['labelFrame'])
        return 3 + (per_digit * len(str(bar)) if horizontal else frames[0]['height'])

    def fits(kk):
        nb = [i for i in down if (bars[i] - 1) % kk == 0]
        return all(ax(times[b]) - ax(times[a]) >= ext(bars[a]) + GAP - 1e-6 for a, b in zip(nb, nb[1:]))
    if not fits(k):
        return False, f'k={k}: labels closer than {GAP} pt', None
    if k > 1 and fits(k // 2):
        return False, f'k={k} not minimal', None
    for f in frames:
        if f['x'] < 0 or f['y'] < 0 or f['x'] + f['width'] > r['size']['width'] or f['y'] + f['height'] > r['size']['height']:
            return False, f'label frame {f} leaves the strip', None
    for b, m in numbered.items():  # a missing label must be one that would leave the strip
        if m['labelFrame'] is None and m['axis'] + ext(b) <= L - 1:
            return False, f'label of bar {b} missing', None
    spaced = lambda idx: all(ax(times[b]) - ax(times[a]) >= 4 - 1e-6 for a, b in zip(idx, idx[1:]))  # noqa: E731
    small_all = spaced(vis)
    small_down = not small_all and spaced([i for i in down if (bars[i] - 1) % k])
    want = []
    for i in vis:
        b = beats[i]
        if bars[i] and (bars[i] - 1) % k == 0:
            want.append((round(times[i], 6), 'bigDotted' if b['firstBeat'] == 'computed' else 'big', bars[i]))
        elif small_all or (small_down and bars[i]):
            want.append((round(times[i], 6), 'dot' if b['source'] == 'computed' else 'small', None))
    have = [(round(m['time'], 6), m['kind'], m['bar']) for m in marks]
    if have != want:
        diff = next((j for j, (a, b) in enumerate(zip(have, want)) if a != b), min(len(have), len(want)))
        return False, f'marks differ at {diff}: {have[diff:diff + 3]} want {want[diff:diff + 3]} ({len(have)} vs {len(want)})', None
    info = {'k': k, 'small': 'all' if small_all else 'downbeats' if small_down else 'none', 'marks': len(marks),
            'kinds': sorted({m['kind'] for m in marks}), 'bars': sorted(numbered)}
    return True, f'k={k}, small marks: {info["small"]}, {len(marks)} marks {info["kinds"]}', info


def read_png(path):
    """RGB array of a PNG (via sips → BMP)."""
    bmp = path[:-4] + '.bmp'
    subprocess.run(['sips', '-s', 'format', 'bmp', path, '--out', bmp], check=True, capture_output=True)
    b = open(bmp, 'rb').read()
    off, w, h, bpp = struct.unpack('<I', b[10:14])[0], *struct.unpack('<ii', b[18:26]), struct.unpack('<H', b[28:30])[0]
    rowlen = (w * bpp // 8 + 3) & ~3
    a = np.frombuffer(b[off:off + rowlen * abs(h)], np.uint8).reshape(abs(h), rowlen)[:, :w * bpp // 8]
    a = a.reshape(abs(h), w, bpp // 8)[:, :, 2::-1]
    return a if h < 0 else a[::-1]


def ruler_point(s, t, cross):
    r = s.state['screenFrames']['ruler']
    vs, ve = s.view()
    f = (t - vs) / (ve - vs)
    if s.state['orientation'] == 'horizontal':
        return r['x'] + f * r['width'], r['y'] + cross
    return r['x'] + cross, r['y'] + f * r['height']


def rp(s, t):
    r = s.state['ruler']['size']
    return P(ruler_point(s, t, (r['height'] if s.state['orientation'] == 'horizontal' else r['width']) / 2))


subprocess.run(['defaults', 'delete', DOMAIN, 'showBeats'], capture_output=True)

for orientation in ['horizontal', 'vertical']:
    o = orientation[0]
    s = Session(f'{o}_main', [MAIN_WAV], orientation)
    s.command('loop off'); s.command('follow off'); s.command('select')

    # 3. Beats mode, several views, two window sizes
    for size in ['1000,700', '700,450']:
        s.command(f'resize {size}')
        for view in [(0, 10), (2, 4), (0, 1)]:
            s.command(f'view {view[0]},{view[1]}'); s.dump()
            ok, detail, info = beat_check(s, want, SR)
            if ok and view == (0, 10):
                ok = info['k'] == 1 and info['small'] == 'all' and set(info['kinds']) == {'big', 'bigDotted', 'small', 'dot'} \
                    and info['bars'] == [1, 2, 3, 4, 5]
                detail += f', bars {info["bars"]}' if ok else f' -- expected k=1, all kinds, bars 1–5: {info}'
            check(3, f'{orientation} {size}: view {view[0]}–{view[1]}: {detail}', ok, detail)
            s.snapshot(f'beats_{size.replace(",", "x")}_{view[0]}-{view[1]}')

    # 4. Crowding with the dense list
    s.command('resize 1000,700')
    s.command(f'open {DENSE_WAV}'); s.dump()
    seen = []
    for view in [None, (0, 150), (0, 60), (0, 10)]:
        s.command(f'view {view[0]},{view[1]}' if view else 'view -1,800'); s.dump()
        ok, detail, info = beat_check(s, DENSE, LONG_SR)
        seen.append(info)
        check(4, f'{orientation}: dense list, view {s.view()[0]:.2f}–{s.view()[1]:.2f}: {detail}', ok, detail)
        s.snapshot(f'dense_{view[1] if view else "whole"}')
    if all(seen):
        check(4, f'{orientation}: zooming in: k {[i["k"] for i in seen]} decreasing to 1, small marks '
              f'{[i["small"] for i in seen]} (none → downbeats → all)',
              seen[0]['k'] > seen[-1]['k'] == 1 and seen[0]['small'] == 'none' and seen[-1]['small'] == 'all'
              and 'downbeats' in [i['small'] for i in seen], seen)
    s.command(f'open {MAIN_WAV}'); s.command('view 2,6'); s.dump()

    # 6. The marks follow view changes
    steps = []
    nav_mid = P(s.at('navigator', 0.5))
    s.input(f'scroll {nav_mid} {120 if o == "h" else 0} {0 if o == "h" else 120} cmd')
    steps.append(('zoom', s.view(), beat_check(s, want, SR)))
    s.input(f'scroll {nav_mid} 60 0' if o == 'h' else f'scroll {nav_mid} 0 60')
    steps.append(('pan', s.view(), beat_check(s, want, SR)))
    s.command('resize 800,500'); s.dump()
    steps.append(('resize', s.view(), beat_check(s, want, SR)))
    c, dv = s.state['screenFrames']['content'], s.state['paneFrames']['divider']
    mid = (c['x'] + dv['x'] + dv['width'] / 2, c['y'] + dv['y'] + dv['height'] / 2)
    to = (mid[0], mid[1] + 50) if o == 'h' else (mid[0] + 50, mid[1])
    frac0 = s.state['navigatorFraction']
    s.input(f'drag {P(mid)} {P(to)}')
    steps.append(('divider', s.state['navigatorFraction'], beat_check(s, want, SR)))
    s.command(f'orientation {"vertical" if o == "h" else "horizontal"}'); s.dump()
    steps.append(('orientation', s.view(), beat_check(s, want, SR)))
    s.command(f'orientation {orientation}'); s.command('resize 1000,700'); s.dump()
    check(6, f'{orientation}: marks match the view after zoom, pan, resize, divider drag and orientation switch',
          all(r[2][0] for r in steps) and s.state['navigatorFraction'] != frac0,
          [(n, v, r[1]) for n, v, r in steps if not r[0]])

    # 7. Pointer line
    s.command('view 0,10'); s.command('playhead 0.2'); s.dump()
    L = s.length('navigator')
    res = {}
    for mode in ['on', 'off']:
        s.command(f'beats {mode}'); s.dump()
        for pane, f in [('navigator', 0.31), ('ruler', 0.47), ('main', 0.63)]:
            s.input(f'move {P(s.at(pane, f))}')
            res[(mode, pane)] = (s.state['ruler']['pointerAxis'], f * L)
        sb, tr = s.state['screenFrames']['scrollbar'], s.state['paneFrames']['transport']
        cont = s.state['screenFrames']['content']
        s.input(f'move {P((sb["x"] + sb["width"] / 2, sb["y"] + sb["height"] / 2))}')
        res[(mode, 'scrollbar')] = (s.state['ruler']['pointerAxis'], None)
        s.input(f'move {P((cont["x"] + tr["x"] + tr["width"] * 0.6, cont["y"] + tr["y"] + tr["height"] / 2))}')
        res[(mode, 'transport')] = (s.state['ruler']['pointerAxis'], None)
    s.command('beats on')
    bad7 = {k: v for k, v in res.items() if (v[1] is None) != (v[0] is None) or (v[1] is not None and abs(v[0] - v[1]) > 0.5)}
    check(7, f'{orientation}: pointer over the navigator, the strip and the main pane: the line at the pointer\'s time '
          '(within 0.5 pt), in beats and time mode; over the scrollbar and the transport pane: no line',
          not bad7, bad7)
    s.command('view 2,6'); s.dump()
    s.input(f'move {P(s.at("navigator", 0.4))}')
    v0, a0 = s.view(), s.state['ruler']['pointerAxis']
    s.input(f'scroll {P(s.at("navigator", 0.4))} 80 0' if o == 'h' else f'scroll {P(s.at("navigator", 0.4))} 0 80')
    v1, a1 = s.view(), s.state['ruler']['pointerAxis']
    t0 = v0[0] + 0.4 * (v0[1] - v0[0])
    t1 = v1[0] + a1 / L * (v1[1] - v1[0]) if a1 is not None else None
    check(7, f'{orientation}: pointer held still, a pan moves the view ({v0[0]:.2f} → {v1[0]:.2f}); the line shows '
          f'the pointer\'s new time ({t0:.3f} → {t1})',
          v1 != v0 and a1 is not None and abs(a1 - 0.4 * L) <= 0.5 and t1 is not None and abs(t1 - t0) > 0.1,
          f'{v0} {a0} {v1} {a1}')
    # Pixel check: a point of the strip at the pointer line vs. next to it.
    s.command('view 0,10'); s.dump()
    tp = 6.25 + (0.0 if o == 'h' else 0.0)  # between the beats at 6.0 and 6.5
    rs = s.state['ruler']['size']
    cross = 3 if o == 'h' else rs['width'] - 7
    x, y = ruler_point(s, tp, cross)
    s.input(f'move {P((x, y))}')
    s.snapshot('pointer')
    img = read_png(os.path.abspath(f'{OUT}/{s.name}_pointer.png'))
    c = s.state['screenFrames']['content']
    scale = img.shape[1] / c['width']
    top = c['y'] + c['height'] - img.shape[0] / scale

    def px(x, y, d=(0,)):
        r0, c0 = int(round((y - top) * scale)), int(round((x - c['x']) * scale))
        return [img[r0 + (k if o == 'v' else 0), c0 + (k if o == 'h' else 0)].astype(int) for k in d]
    on_line = min(px(x, y, (-1, 0, 1)), key=lambda p: int(p.sum()))
    off = ruler_point(s, tp + 0.08, cross)
    beside = px(*off)[0]
    check(7, f'{orientation}: screenshot: the pointer line is visible in the strip ({list(on_line)} vs '
          f'{list(beside)} beside it)', beside.sum() - on_line.sum() > 60 and s.state['ruler']['pointerAxis'] is not None,
          s.state['ruler']['pointerAxis'])

    # 8. Strip mouse in beats mode
    s.command('select 2,3'); s.dump()
    tol = 10 / L + 1e-9
    s.input(f'click {rp(s, 5.0)}')
    p = pb(s)
    clicked = (p['playhead'], p['lastStart'], s.sel(), p['playing'])
    s.input(f'drag {rp(s, 5.0)} {rp(s, 6.0)}')
    p = pb(s)
    dragged = (p['playhead'], s.sel(), p['playing'], s.state['ruler']['mode'])
    near = lambda a, b: abs(a - b) <= tol  # noqa: E731
    check(8, f'{orientation}: beats mode: a strip click at 5.0 puts the playhead and last start there; a drag '
          '5 → 6 moves the playhead to 6; the selection stays 2–3; no playback',
          near(clicked[0], 5.0) and near(clicked[1], 5.0) and clicked[2] == (2, 3) and not clicked[3]
          and near(dragged[0], 6.0) and dragged[1] == (2, 3) and not dragged[2] and dragged[3] == 'beats',
          f'{clicked} {dragged}')
    s.command('select')
    s.quit()

# 5. Toggle
subprocess.run(['defaults', 'delete', DOMAIN, 'showBeats'], capture_output=True)


def menu_item(s):
    view = next((m for m in s.state['menu'] if m['title'] == 'View'), {'items': []})
    return next((i for i in view['items'] if i['title'] == 'Show Beats'), None)


def strip_mode(s):
    r = s.state['ruler']
    return r['mode'], len(r['marks']), sum(1 for t in r['ticks'] if t['major'])


s = Session('c5', [MAIN_WAV])
pid = s.proc.pid
default = (s.state['showBeats'], strip_mode(s), menu_item(s))
s.input(f'press {pid} Show Beats')
pressed = (s.state['showBeats'], strip_mode(s))
s.input('key b cmd')
keyed = (s.state['showBeats'], strip_mode(s), menu_item(s))
s.input('key b cmd')
off = (s.state['showBeats'], strip_mode(s), menu_item(s))
s.quit()
check(5, 'default: beats mode (beat marks, no time ticks); View → Show Beats ⌘B present, enabled, checked',
      default[0] == {'stored': True, 'enabled': True, 'on': True} and default[1][0] == 'beats' and default[1][1] > 0
      and default[1][2] == 0 and default[2] and default[2].get('shortcut') == 'cmd+b' and default[2]['enabled']
      and default[2]['checked'], default)
check(5, 'toolbar Show Beats → time mode (milestone 5 time ticks); ⌘B → beats again; ⌘B → time, menu unchecked',
      not pressed[0]['on'] and pressed[1][0] == 'time' and pressed[1][2] > 0 and pressed[1][1] == 0
      and keyed[0]['on'] and keyed[1][0] == 'beats' and keyed[2]['checked']
      and not off[0]['on'] and off[1][0] == 'time' and not off[2]['checked'], f'{pressed} {keyed} {off}')
s = Session('c5_relaunch', [MAIN_WAV])
pid = s.proc.pid
relaunched = (s.state['showBeats'], strip_mode(s))
s.input('key b cmd')
s.command(f'open {NOBEATS}'); s.dump()
ax = s.input(f'enabled {pid} Show Beats')
none = (s.state['showBeats'], strip_mode(s), menu_item(s), ax)
s.input('key b cmd')  # disabled: no effect
none2 = s.state['showBeats']
s.command(f'open {MAIN_WAV}'); s.dump()
back = (s.state['showBeats'], strip_mode(s))
s.quit()
check(5, 'the choice (time) survives a relaunch', not relaunched[0]['stored'] and relaunched[1][0] == 'time', relaunched)
check(5, 'a file without beats: button and menu item disabled (AX + menu), strip shows time, stored choice (beats) '
      'kept; ⌘B does nothing; the next file with beats shows beats',
      none[0] == {'stored': True, 'enabled': False, 'on': False} and none[1][0] == 'time' and none[1][2] > 0
      and not none[2]['enabled'] and none[3] == ['false'] and none2 == none[0]
      and back[0]['on'] and back[1][0] == 'beats', f'{none} {none2} {back}')
s = Session('c5_vertical', [MAIN_WAV], 'vertical')
r = s.state['ruler']
widest_bar = max(m['labelFrame']['width'] for m in r['marks'] if m['labelFrame'])
s.command('beats off'); s.dump()
r2 = s.state['ruler']
widest_time = max(t['labelFrame']['width'] for t in r2['ticks'] if t['labelFrame'])
s.command('beats on')
s.quit()
check(5, f'vertical strip {r["size"]["width"]} pt wide in both modes, ≥ 3 + the widest bar number ({widest_bar}) and '
      f'time label ({widest_time})',
      r['size']['width'] == r2['size']['width'] >= 3 + max(widest_bar, widest_time), f'{r["size"]} {r2["size"]}')

print(f'\n{sum(results)}/{len(results)} checks passed')
sys.exit(0 if all(results) else 1)
