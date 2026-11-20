"""Checks milestone 7 acceptance criteria (placing and editing beats, computed beats and bars).
Run from prototype/: python3 verify/verify_m7.py

Needs Accessibility and Screen Recording permission for the terminal. Don't touch the mouse or
keyboard while it runs. Screenshots: verify/out/m7/*.png.
Set SKIP_EARLIER=1 to skip criterion 1 (the earlier scripts).
"""
import atexit, json, math, os, stat, subprocess, sys, time

sys.path.insert(0, os.path.dirname(__file__))
import m3session  # noqa: E402
import m4util  # noqa: E402
from m4util import Session, build_driver, check, P, pb, wait_playhead, results, SR, BIN  # noqa: E402

OUT = 'verify/out/m7'
m3session.OUT = m4util.OUT = OUT
m3session.DRIVER = f'{OUT}/inputdriver'
AUDIO = os.path.abspath(f'{OUT}/audio')
NOISE = f'{AUDIO}/noise.wav'
FRAMES = 441000
MIN_D = math.ceil(0.25 * SR)


def kill_leftovers():
    subprocess.run(['pkill', '-f', '^build/TranscribeAndPractice[.]app/'], capture_output=True)


kill_leftovers()
atexit.register(kill_leftovers)

# 1. Earlier milestones
if os.environ.get('SKIP_EARLIER'):
    subprocess.run(['./build.sh'], check=True, capture_output=True)
else:
    r = subprocess.run([sys.executable, 'verify/verify_m6.py'], capture_output=True, text=True)
    fails = [l for l in r.stdout.splitlines() if l.startswith('FAIL')]
    check(1, 'verify_m6.py passes (with verify_m1 … m5, m4_review)', r.returncode == 0 and not fails,
          '\n'.join(fails) or r.stdout[-400:] + r.stderr[-400:])
    kill_leftovers()

os.makedirs(AUDIO, exist_ok=True)
subprocess.run([sys.executable, 'verify/gen_test_audio_m4.py', AUDIO], check=True, capture_output=True)
build_driver()


# --- Reference implementation of the spec's recomputation ---
def rsample(x):
    return math.floor(x + 0.5)


def per_bar(ts):
    n, d = map(int, ts.split('/'))
    return -(-(n * 4) // d)  # ⌈(n/d) ÷ (1/4)⌉


def recompute(beats, sr=SR, frames=FRAMES):
    placed = [dict(b, firstBeat='no' if b['firstBeat'] == 'computed' else b['firstBeat'])
              for b in beats if b['source'] == 'placed']
    out = []
    if len(placed) >= 2:
        cur = None
        for b1, b2 in zip(placed, placed[1:]):
            out.append(b1)
            dt = (b2['sample'] - b1['sample']) / sr
            if cur is not None:
                ideal = cur * dt / 60
                best, err = 0, math.inf
                for n in range(max(math.floor(ideal) - 1, 0), math.ceil(ideal) + 2):
                    e = abs(math.log(cur / ((n + 1) * 60 / dt)))
                    if e < err:
                        best, err = n, e
                for j in range(1, best + 1):
                    out.append({'sample': rsample(b1['sample'] + j * (b2['sample'] - b1['sample']) / (best + 1)),
                                'source': 'computed', 'timeSignature': None, 'firstBeat': 'no'})
                cur = (best + 1) * 60 / dt
            else:
                if 60 / dt >= 30:
                    cur = 60 / dt
        last = placed[-1]
        out.append(last)
        if cur is not None:
            k = 1
            while True:
                s = rsample(last['sample'] + k * 60 / cur * sr)
                if s >= frames:
                    break
                out.append({'sample': s, 'source': 'computed', 'timeSignature': None, 'firstBeat': 'no'})
                k += 1
    else:
        out = placed
    sig, bib = None, 1
    for b in out:
        if b.get('timeSignature'):
            sig = b['timeSignature']
        if sig is None:
            continue
        if b['firstBeat'] == 'placed':
            bib = 1
        elif bib == 1:
            b['firstBeat'] = 'computed'
        bib = bib % per_bar(sig) + 1
    return out


def norm(beats):
    return [(b['sample'], b['source'], b.get('timeSignature'), b['firstBeat']) for b in beats]


def pb_(t, first='no', ts=None, source='placed'):
    d = {'sample': int(round(t * SR)), 'source': source, 'firstBeat': first}
    if ts:
        d['timeSignature'] = ts
    return d


def audio_with(name, sidecar):
    p = f'{AUDIO}/{name}.wav'
    if os.path.lexists(p):
        os.remove(p)
    os.symlink('noise.wav', p)
    side = p + '.beats.json'
    if os.path.exists(side):
        os.remove(side)
    if sidecar is not None:
        json.dump(sidecar, open(side, 'w'))
    return p


def sidecar(path):
    return json.load(open(path + '.beats.json'))


def ruler_point(s, t, cross=None):
    r = s.state['screenFrames']['ruler']
    vs, ve = s.view()
    f = (t - vs) / (ve - vs)
    rs = s.state['ruler']['size']
    if s.state['orientation'] == 'horizontal':
        return r['x'] + f * r['width'], r['y'] + (rs['height'] / 2 if cross is None else cross)
    return r['x'] + (rs['width'] / 2 if cross is None else cross), r['y'] + f * r['height']


def rp(s, t):
    return P(ruler_point(s, t))


def pane_point(s, pane, t):
    vs, ve = s.view()
    return P(s.at(pane, (t - vs) / (ve - vs)))


def beats(s):
    return s.state['beats']


def placed_of(bs):
    return [b for b in bs if b['source'] == 'placed']


def ref_ok(s, what):
    """The dumped beats equal the reference recomputation of the dumped placed beats."""
    got = beats(s)
    want = recompute(placed_of(got))
    return norm(got) == norm(want), f'{what}: {len(got)} beats vs reference {len(want)}; first diff ' + str(
        next(((a, b) for a, b in zip(norm(got), norm(want)) if a != b), None))


def key(s, k):
    s.input(f'key {k}')


# 2. Recomputation against the reference: sidecar placed beats + one B at the end
CONFIGS = {
    'two beats (120 BPM), extrapolated': ([pb_(1.0, 'placed', '4/4')], 1.5),
    'N = 0, 1, 3 (tempo changes)': ([pb_(1.0, 'placed', '4/4'), pb_(1.5), pb_(2.0), pb_(3.0), pb_(5.0)], 5.52),
    'first pair slower than 30 BPM': ([pb_(0.5, 'placed', '3/4'), pb_(3.0), pb_(3.6), pb_(4.9)], 5.4),
    'time signatures 3/4 → 6/8 mid-file': ([pb_(0.5, 'placed', '3/4'), pb_(1.0), pb_(3.0, 'placed', '6/8')], 3.5),
    '5/8 (3 per bar)': ([pb_(0.5, 'placed', '5/8'), pb_(1.0)], 1.5),
    '7/8 (4 per bar) and a placed downbeat resetting the bar': ([pb_(0.5, 'placed', '7/8'), pb_(1.0), pb_(2.7, 'placed')], 3.2),
    'no time signature: no bars': ([pb_(0.5), pb_(1.2)], 2.0),
}
s = Session('c2', [audio_with('c2_0', None)])
s.command('loop off'); s.command('follow off')
for i, (name, (side, extra)) in enumerate(CONFIGS.items()):
    p = audio_with(f'c2_{i}', side)
    s.command(f'open {p}'); s.command('view 0,10'); s.dump()
    s.input(f'move {pane_point(s, "navigator", extra)}', 'key b')
    ok, detail = ref_ok(s, name)
    added = len(placed_of(beats(s))) == len(side) + 1
    kinds = sorted({b['firstBeat'] for b in beats(s)})
    check(2, f'{name}: {len(beats(s))} beats (firstBeat {kinds}) equal the reference, sample-exact', ok and added, detail)
    if i == 1:  # the inserted counts per pair
        pl = [b['sample'] for b in placed_of(beats(s))]
        counts = [sum(1 for b in beats(s) if a < b['sample'] < c) for a, c in zip(pl, pl[1:])]
        check(2, f'{name}: computed beats per placed pair {counts} (want [0, 0, 1, 3, …])', counts[:4] == [0, 0, 1, 3], counts)
s.quit()

for orientation in ['horizontal', 'vertical']:
    o = orientation[0]
    # 3. Placing
    s = Session(f'{o}_c3', [audio_with(f'{o}_c3', [pb_(5.0, 'placed', '4/4')])], orientation)
    s.command('loop off'); s.command('follow off'); s.command('view 0,10'); s.dump()
    L = s.length('navigator')
    res = []
    for pane, t, k in [('navigator', 1.0, 'b'), ('ruler', 2.0, 'b'), ('main', 3.0, 'b shift')]:
        before = {b['sample'] for b in beats(s)}
        s.input(f'move {pane_point(s, pane, t)}' if pane != 'ruler' else f'move {rp(s, t)}')
        ax = s.state['ruler']['pointerAxis']
        vs, ve = s.view()
        pt = vs + ax / L * (ve - vs)
        s.input(f'key {k}')
        if s.state['timeSignatureDialog']['shown']:  # the 1.0 beat is the new first one
            s.command('tsdialog dontset'); s.dump()
        new = [b for b in placed_of(beats(s)) if b['sample'] not in before]
        res.append((pane, k, new, pt))
    ok = all(len(n) == 1 and abs(n[0]['sample'] - pt * SR) <= SR * (ve - vs) / L
             and n[0]['firstBeat'] == ('placed' if 'shift' in k else 'no') for _, k, n, pt in res)
    check(3, f'{orientation}: B over the navigator (1.0), the strip (2.0), Shift+B over the main pane (3.0): placed beats '
          'at the pointer\'s sample, Shift+B a placed downbeat; the rest recomputed', ok and ref_ok(s, 'c3')[0],
          [(p, k, n, round(pt * SR)) for p, k, n, pt in res])
    beeps = s.state['beepCount']
    n0 = norm(beats(s))
    s.input(f'move {pane_point(s, "navigator", 2.2)}', 'key b')
    near = (s.state['beepCount'] - beeps, norm(beats(s)) == n0)
    sb = s.state['screenFrames']['scrollbar']
    s.input(f'move {P((sb["x"] + sb["width"] * 0.7, sb["y"] + sb["height"] / 2))}', 'key b')
    outside = (s.state['beepCount'] - beeps, norm(beats(s)) == n0)
    check(3, f'{orientation}: refused with a beep, no change: within 0.25 s of a placed beat (2.2 vs 2.0), the pointer over '
          'the scrollbar', near == (1, True) and outside == (2, True), f'{near} {outside}')
    s.command('playhead 6.0'); s.dump()
    s.input(f'move {P((sb["x"] + sb["width"] * 0.1, sb["y"] + sb["height"] / 2))}')
    s.input('key space')
    wait_playhead(s, 6.6)
    s.dump()
    ph0 = pb(s)['playhead']
    before = {b['sample'] for b in beats(s)}
    s.input('key b')
    ph1 = pb(s)['playhead']
    s.input('key space')
    new = [b for b in placed_of(beats(s)) if b['sample'] not in before]
    check(3, f'{orientation}: during playback (pointer over the scrollbar) B places at the playhead '
          f'({ph0:.3f} … {ph1:.3f}): {[n["sample"] / SR for n in new]}',
          len(new) == 1 and ph0 * SR - 800 <= new[0]['sample'] <= ph1 * SR + 800, new)
    s.quit()
    if o == 'h':
        s = Session('c3_nofile', [])
        s.input(f'move {P(s.at("main", 0.5))}', 'key b')
        check(3, 'no file loaded: B beeps', s.state['beepCount'] == 1 and beats(s) == [], s.state['beepCount'])
        s.quit()

    # 5. Strip editing
    base = recompute([pb_(1.0, 'placed', '4/4'), pb_(1.5), pb_(2.0), pb_(4.0, 'no', '3/4')])
    path = audio_with(f'{o}_c5', base)
    s = Session(f'{o}_c5', [path], orientation)
    s.command('loop off'); s.command('follow off'); s.command('view 0,5'); s.dump()
    s.input(f'move {rp(s, 1.5)}')
    hover = (s.state['ruler']['cursor'], s.state['hoveredBeat'])
    s.input(f'down {rp(s, 1.5)}', f'dragto {rp(s, 1.62)}')
    mid = (ref_ok(s, 'mid-drag'), s.state['ruler']['cursor'], [b['sample'] for b in placed_of(beats(s))][1])
    s.input(f'up {rp(s, 1.62)}')
    after = [b['sample'] for b in placed_of(beats(s))]
    file_ok = norm(sidecar(path)) == norm(beats(s))
    s.input(f'drag {rp(s, after[1] / SR)} {rp(s, 1.95)}')
    limit = [b['sample'] for b in placed_of(beats(s))][1]
    tol = SR * 5 / s.length('navigator')
    check(5, f'{orientation}: hovering a beat mark: {hover[0]}, hovered {hover[1]}; dragging 1.5 → 1.62: closed hand, live '
          f'recompute mid-drag ({mid[2] / SR:.3f}); saved on release; dragging towards 2.0 stops at 1.75 ({limit / SR:.4f})',
          hover == ('openHand', int(1.5 * SR)) and mid[0][0] and mid[1] == 'closedHand' and abs(mid[2] - 1.62 * SR) <= tol
          and abs(after[1] - 1.62 * SR) <= tol and file_ok and limit == int(2.0 * SR) - MIN_D and ref_ok(s, 'drag')[0],
          f'{hover} {mid} {after[1]} {file_ok} {limit}')
    comp = next(b for b in beats(s) if b['source'] == 'computed' and 2.6 < b['sample'] / SR < 3.4)
    s.input(f'drag {rp(s, comp["sample"] / SR)} {rp(s, comp["sample"] / SR + 0.1)}')
    moved = [b for b in beats(s) if abs(b['sample'] - (comp['sample'] + 0.1 * SR)) <= tol]
    check(5, f'{orientation}: dragging a computed beat ({comp["sample"] / SR:.3f}, firstBeat {comp["firstBeat"]}) makes it '
          'placed; firstBeat as the recomputation gives it', len(moved) == 1 and moved[0]['source'] == 'placed'
          and ref_ok(s, 'computed drag')[0], moved)
    n0 = norm(beats(s))
    s.input(f'click {rp(s, 1.0)}')
    clicked = (pb(s)['playhead'], norm(beats(s)) == n0)
    comp = next(b for b in beats(s) if b['source'] == 'computed')
    beeps = s.state['beepCount']
    s.input(f'move {rp(s, comp["sample"] / SR)}', 'key backspace')
    kept = (s.state['beepCount'] - beeps, norm(beats(s)) == n0)
    s.input(f'move {rp(s, 2.0)}', 'key backspace')
    deleted = all(abs(b['sample'] - 2.0 * SR) > 10 or b['source'] == 'computed' for b in beats(s)) and ref_ok(s, 'delete')[0]
    s.input(f'move {rp(s, 1.0)}', 'key backspace')
    pl = placed_of(beats(s))
    ts_moved = pl[0]['sample'] != int(1.0 * SR) and pl[0].get('timeSignature') == '4/4'
    check(5, f'{orientation}: a click on a mark moves the playhead ({clicked[0]:.3f}), beats unchanged; Backspace: computed '
          'beat beeps and stays, placed beat at 2.0 deleted; deleting the first beat (4/4) moves 4/4 to the new first beat',
          abs(clicked[0] - 1.0) <= tol / SR and clicked[1] and kept == (1, True) and deleted and ts_moved,
          f'{clicked} {kept} {deleted} {pl[:2]}')
    # The mid-file signature (3/4 at 4.0): delete it, the next placed beat takes it.
    s.command('view 0,10'); s.dump()
    s.input(f'move {pane_point(s, "navigator", 6.0)}', 'key b')
    s.input(f'move {rp(s, 4.0)}', 'key backspace')
    pl = placed_of(beats(s))
    check(5, f'{orientation}: deleting the beat with 3/4 (4.0) moves 3/4 to the next placed beat (6.0)',
          any(abs(b['sample'] - 6.0 * SR) < tol and b.get('timeSignature') == '3/4' for b in pl)
          and not any(abs(b['sample'] - 4.0 * SR) < 10 for b in pl), pl)
    # During playback: no grab, no delete
    n0 = norm(beats(s))
    target = pl[0]['sample'] / SR
    s.command('playhead 0.2'); s.dump()
    s.input('key space')
    wait_playhead(s, 0.4)
    s.input(f'move {rp(s, target)}')
    cur = s.state['ruler']['cursor']
    s.input('key backspace')
    s.input(f'drag {rp(s, target)} {rp(s, target + 0.3)}')
    playing = (cur, norm(beats(s)) == n0, pb(s)['playing'], pb(s)['lastStart'])
    s.input('key space')
    check(5, f'{orientation}: during playback a beat mark shows no hand ({cur}), Backspace and a drag on it change no beat '
          '(the press seeks playback as a strip press)', cur != 'openHand' and playing[1] and playing[2]
          and abs(playing[3] - target) <= tol / SR, playing)
    s.quit()

# 4. Time signature dialog (horizontal)
path = audio_with('c4', None)
s = Session('c4', [path])
pid = s.proc.pid
s.command('loop off'); s.command('follow off'); s.command('view 0,10'); s.dump()
s.input(f'move {pane_point(s, "navigator", 3.0)}', 'key b')
d = s.state['timeSignatureDialog']
s.snapshot('dialog')
first = dict(d)
s.command('tsdialog numerator 1a2b'); s.dump()
filtered = s.state['timeSignatureDialog']['numerator']
s.command('tsdialog numerator 7'); s.command('tsdialog denominator 8'); s.dump()
r = s.input(f'press {pid} OK')
ok_set = (r, s.state['timeSignatureDialog']['shown'], placed_of(beats(s))[0].get('timeSignature'))
check(4, 'the first beat opens the dialog: numerator 4, denominator 4 of 1 … 128, OK enabled; the numerator keeps digits '
      f'only ("1a2b" → "{filtered}"); 7 / 8 + OK (Accessibility press) sets 7/8 on the beat',
      first['shown'] and first['sheetVisible'] and first['numerator'] == '4' and first['denominator'] == 4
      and first['denominatorOptions'] == [1, 2, 4, 8, 16, 32, 64, 128] and first['okEnabled'] and filtered == '12'
      and ok_set == (['pressed'], False, '7/8'), f'{first} {filtered} {ok_set}')
s.input(f'move {pane_point(s, "navigator", 5.0)}', 'key b')
later = s.state['timeSignatureDialog']['shown']
s.input(f'move {pane_point(s, "navigator", 1.0)}', 'key b')
before_all = s.state['timeSignatureDialog']['shown']
r = s.input(f'press {pid} Don\'t set')
pl = placed_of(beats(s))
check(4, 'a later beat (5.0): no dialog; a beat before all others (1.0): dialog; "Don\'t set" leaves it without a '
      'signature, 7/8 stays on the 3.0 beat',
      not later and before_all and r == ['pressed'] and pl[0].get('timeSignature') is None
      and pl[1].get('timeSignature') == '7/8' and not s.state['timeSignatureDialog']['shown'], f'{later} {before_all} {r} {pl[:2]}')
s.command('playhead 0.1'); s.dump()
s.input('key space')
wait_playhead(s, 0.3)
s.input('key b')
during = dict(s.state['timeSignatureDialog'])
first_now = placed_of(beats(s))[0]['sample'] / SR
s.input('key space')
time.sleep(0.3)
s.dump()
after_stop = s.state['timeSignatureDialog']
s.snapshot('dialog_after_stop')
s.command('tsdialog ok'); s.dump()
check(4, f'during playback a beat before all others ({first_now:.3f}): no dialog while playing (pending); shown after '
      'the stop; OK sets 4/4', not during['shown'] and during['pending'] and after_stop['shown'] and not after_stop['pending']
      and placed_of(beats(s))[0].get('timeSignature') == '4/4', f'{during} {after_stop}')
s.quit()

# 6. Autosave
path = audio_with('c6', [pb_(1.0, 'placed', '4/4')])
s = Session('c6', [path])
s.command('view 0,10'); s.dump()
steps = []
s.input(f'move {pane_point(s, "navigator", 1.5)}', 'key b')
steps.append(norm(sidecar(path)) == norm(beats(s)))
s.input(f'move {pane_point(s, "navigator", 2.5)}', 'key b shift')
steps.append(norm(sidecar(path)) == norm(beats(s)))
s.input(f'drag {rp(s, 2.5)} {rp(s, 2.7)}')
steps.append(norm(sidecar(path)) == norm(beats(s)))
s.input(f'move {rp(s, 1.5)}', 'key backspace')
steps.append(norm(sidecar(path)) == norm(beats(s)))
final = norm(beats(s))
s.command(f'open {NOISE}'); s.command(f'open {path}'); s.dump()
restored = norm(beats(s)) == final
s.quit()
check(6, f'after placing, Shift+placing, dragging and deleting, the sidecar equals the dumped beats {steps}; '
      'reopening restores them', all(steps) and restored and len(final) > 3, f'{steps} {restored}')
rodir = os.path.abspath(f'{OUT}/readonly')
os.makedirs(rodir, exist_ok=True)
os.chmod(rodir, 0o755)
ro = f'{rodir}/ro.wav'
if os.path.lexists(ro):
    os.remove(ro)
os.symlink(NOISE, ro)
json.dump([pb_(1.0, 'placed', '4/4')], open(ro + '.beats.json', 'w'))
os.chmod(rodir, 0o555)
try:
    s = Session('c6_ro', [ro])
    s.command('view 0,10'); s.dump()
    s.input(f'move {pane_point(s, "navigator", 1.5)}', 'key b')
    st = s.state
    s.quit()
finally:
    os.chmod(rodir, 0o755)
check(6, f'sidecar in a read-only folder: alert “{st["alertTitle"]}”: {st["alertText"]}; the beats kept in memory',
      st['alertTitle'] == 'Could not save beats' and 'ro.wav.beats.json' in (st['alertText'] or '')
      and len(placed_of(st['beats'])) == 2 and len(sidecar(ro)) == 1, st['alertText'])

print(f'\n{sum(results)}/{len(results)} checks passed')
sys.exit(0 if all(results) else 1)
