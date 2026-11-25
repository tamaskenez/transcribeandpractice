"""Milestone 12 checks (in progress): beats without source, bar layout with a default 4/4,
beat selection, moving, the context menu and its dialogs.
Run from prototype/: python3 verify/verify_m12.py

Needs Accessibility and Screen Recording permission for the terminal. Don't touch the mouse or
keyboard while it runs. Screenshots: verify/out/m12/*.png. ONLY=1,3 runs selected parts.
"""
import atexit, json, os, subprocess, sys, time
import numpy as np

sys.path.insert(0, os.path.dirname(__file__))
import m3session  # noqa: E402
import m4util  # noqa: E402
from m4util import Session, build_driver, check, results, DOMAIN  # noqa: E402
from gen_test_audio_m2 import write_float_wav  # noqa: E402

OUT = 'verify/out/m12'
os.makedirs(OUT, exist_ok=True)
m3session.OUT = m4util.OUT = OUT
DRIVER = m3session.DRIVER = f'{OUT}/inputdriver'
AUDIO = os.path.abspath(f'{OUT}/audio')
ONLY = set(os.environ.get('ONLY', '').split(',')) - {''}
ORIENTATIONS = ('horizontal', 'vertical')
SR = 44100
MIN_DIST = round(0.25 * SR + 0.4999)  # ceil
KEYS = ['timeOrientation', 'followPlayhead', 'mainPaneMode', 'showBeats']


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
rng = np.random.default_rng(12)
AUDIO_PATH = f'{AUDIO}/beats.wav'
write_float_wav(AUDIO_PATH, (0.01 * rng.standard_normal(SR * 20)).astype(np.float32)[:, None], SR)
SIDE = AUDIO_PATH + '.beats.json'


def write_side(beats):
    json.dump(beats, open(SIDE, 'w'))


def read_side():
    return json.load(open(SIDE))


# --- Reference bar layout (the spec's rules) ---
def per_bar(sig):
    n, d = map(int, sig.split('/'))
    return max(-(-4 * n // d), 1)  # ceil((n/d) / (1/4))


def truncated(sig, k):
    n, d = map(int, sig.split('/'))
    return f'{k * d // 4}/{d}' if (k * d) % 4 == 0 else f'{k}/4'


def ref_layout(beats):
    """beats: dicts with firstBeat auto|start, optional timeSignature -> [(bar, beatInBar, effective)]."""
    n = len(beats)
    if not n:
        return []
    forced = [i for i, b in enumerate(beats) if b['firstBeat'] == 'start' or b.get('timeSignature')]
    first = forced[0] if forced else 0
    sig = beats[first].get('timeSignature') or '4/4'
    out = [None] * n
    p0 = per_bar(sig)
    for j in range(first):
        d = first - j - 1
        bib = p0 - d % p0
        out[j] = (-(d // p0), bib, sig if bib == 1 else None)
    i, bar = first, 1
    while i < n:
        if beats[i].get('timeSignature'):
            sig = beats[i]['timeSignature']
        p = per_bar(sig)
        nf = next((f for f in forced if f > i), None)
        cut = nf is not None and nf < i + p
        end = min(nf if cut else i + p, n)
        eff = truncated(sig, end - i) if cut else sig
        for m in range(i, end):
            out[m] = (bar, m - i + 1, eff if m == i else None)
        bar += 1
        i = end
    return out


def layout_ok(s):
    beats = s.state['beats']
    got = [(b['barNumber'], b['beatInBar'], b['effective']) for b in beats]
    ref = ref_layout(beats)
    return got == ref, f'got {got[:12]} ref {ref[:12]}'


def even_beats(t0=0.5, step=0.5, count=38):
    return [{'sample': int(round((t0 + k * step) * SR)), 'firstBeat': 'auto'} for k in range(count)]


def session(name, o, beats=None):
    if beats is not None:
        write_side(beats)
    s = Session(name, opens=[AUDIO_PATH], orientation=o)
    s.command('resize 1000,700')
    s.command('follow off')
    s.command('mode waveform')
    s.command('beats on')
    s.command('view 0,10')
    s.dump()
    return s


r = subprocess.run(['./build.sh'], capture_output=True, text=True)
check(0, 'builds', r.returncode == 0 and 'error' not in r.stdout + r.stderr, r.stdout[-400:] + r.stderr[-400:])
build_driver()
for k in KEYS:
    subprocess.run(['defaults', 'delete', DOMAIN, k], capture_output=True)

# 1. File format and bar layout
if run(1):
    old = []
    for k, b in enumerate(even_beats(count=12)):
        b = dict(b, source='placed' if k < 3 else 'computed',
                 firstBeat='placed' if k == 2 else ('computed' if k in (6, 10) else 'no'))
        if k == 2:
            b['timeSignature'] = '4/4'
        old.append(b)
    s = session('format', 'horizontal', old)
    check(1, 'an old sidecar (source, placed/computed/no) loads: placed → start, others → auto',
          [b['firstBeat'] for b in s.state['beats']] == ['start' if k == 2 else 'auto' for k in range(12)]
          and s.state['alertText'] is None, str(s.state['alertText']))
    ok, d = layout_ok(s)
    check(1, 'two pickup beats are bar 0 beats 3, 4; bar 1 at the start bar', ok and s.state['beats'][0]['barNumber'] == 0
          and s.state['beats'][0]['beatInBar'] == 3, d)
    s.command('beatsel 5'); s.command('beatmenu Delete'); s.dump()
    side = read_side()
    check(1, 'saved without "source", firstBeat auto/start', all('source' not in b for b in side)
          and {b['firstBeat'] for b in side} <= {'auto', 'start'} and len(side) == 11, str(side[:3]))
    s.quit()

    cases = {
        'no forced bar start: 4/4 from the first beat': [{}] * 9,
        '7 pickup beats before a 3/4 change: bars −2 (partial), −1, 0': [{}] * 7 + [{'timeSignature': '3/4'}] + [{}] * 4,
        '4/4 with a start bar after 5 beats: 4/4, 1/4, 4/4': [{'firstBeat': 'start'}] + [{}] * 4 + [{'firstBeat': 'start'}] + [{}] * 5,
        '6/8 cut to 2 beats: 4/8': [{'timeSignature': '6/8'}] + [{}] * 4 + [{'firstBeat': 'start'}] + [{}] * 2,
        '2/2 cut to 1 beat: 1/4; then 3/4': [{'timeSignature': '2/2'}, {'timeSignature': '3/4'}] + [{}] * 4,
        '7/8 (4 beats per bar) and 5/4': [{'timeSignature': '7/8'}] + [{}] * 8 + [{'timeSignature': '5/4'}] + [{}] * 7,
    }
    for desc, spec in cases.items():
        beats = [dict({'sample': int((0.5 + 0.5 * k) * SR), 'firstBeat': 'auto'}, **e) for k, e in enumerate(spec)]
        s = session('layout', 'horizontal', beats)
        ok, d = layout_ok(s)
        check(1, desc, ok, d)
        s.quit()


def mark_point(s, sample):
    m = next((m for m in s.state['ruler']['marks'] if m['sample'] == sample), None)
    if m is None:
        return None
    r = s.state['screenFrames']['ruler']
    if s.state['orientation'] == 'horizontal':
        return r['x'] + m['axis'], r['y'] + r['height'] / 2
    return r['x'] + r['width'] / 2, r['y'] + m['axis']


def lane_point(s, t):
    v0, v1 = s.view()
    f = (t - v0) / (v1 - v0)
    return s.at('ruler', f)


def samples(s):
    return [b['sample'] for b in s.state['beats']]


def sel(s):
    return s.state['selectedBeats']


def P(xy):
    return f'{xy[0]:.1f} {xy[1]:.1f}'


# 2. Mouse: cursor, selection clicks, moving
if run(2):
    for o in ORIENTATIONS:
        resize = 'resizeLeftRight' if o == 'horizontal' else 'resizeUpDown'
        s = session(f'{o}_mouse', o, even_beats())
        b = samples(s)
        s.input(f'move {P(mark_point(s, b[3]))}')
        check(2, f'{o}: over a beat, no selection: {resize} cursor', s.state['ruler']['cursor'] == resize,
              s.state['ruler']['cursor'])
        s.input(f'move {P(lane_point(s, 1.75))}')
        check(2, f'{o}: empty lane, no selection: arrow', s.state['ruler']['cursor'] == 'arrow', s.state['ruler']['cursor'])
        s.input(f'click {P(mark_point(s, b[3]))}')
        check(2, f'{o}: click on a beat selects only it', sel(s) == [3] and s.state['beatAnchor'] == 3, str(sel(s)))
        s.input(f'click {P(mark_point(s, b[5]))} cmd')
        check(2, f'{o}: ⌘-click adds a beat', sel(s) == [3, 5] and s.state['beatAnchor'] == 5, str(sel(s)))
        s.input(f'click {P(mark_point(s, b[3]))} cmd')
        check(2, f'{o}: ⌘-click on a selected beat removes it', sel(s) == [5], str(sel(s)))
        s.input(f'click {P(mark_point(s, b[9]))} shift')
        check(2, f'{o}: ⇧-click adds the range from the anchor', sel(s) == [5, 6, 7, 8, 9], str(sel(s)))
        s.input(f'click {P(mark_point(s, b[1]))} cmd', f'click {P(mark_point(s, b[2]))} shift')
        check(2, f'{o}: ⇧-click adds to the selection (anchor: the last ⌘-clicked beat)',
              sel(s) == [1, 2, 5, 6, 7, 8, 9], str(sel(s)))
        s.input(f'move {P(lane_point(s, 1.75))}')
        check(2, f'{o}: with a selection the lane shows an open hand', s.state['ruler']['cursor'] == 'openHand',
              s.state['ruler']['cursor'])
        s.snapshot('selected')
        axes = s.state['selectedBeatAxes']
        check(2, f'{o}: the selected beats are drawn ({len(axes)})', len(axes) == 7)
        # Drag from empty lane: all selected beats move by the same amount; others stay.
        before = samples(s)
        a, z = lane_point(s, 4.25), lane_point(s, 4.40)
        s.input(f'drag {P(a)} {P(z)}')
        after = samples(s)
        delta = [after[i] - before[i] for i in range(len(before))]
        moved = {i for i, d in enumerate(delta) if d}
        dsel = {delta[i] for i in sel(s)}
        check(2, f'{o}: dragging moves all selected beats by one amount (+{delta[5] / SR:.3f} s), others stay',
              moved == {1, 2, 5, 6, 7, 8, 9} and len(dsel) == 1 and abs(delta[5] / SR - 0.15) < 0.02,
              f'moved {sorted(moved)} deltas {sorted(dsel)}')
        side = read_side()
        check(2, f'{o}: saved after the move', [x['sample'] for x in side] == after)
        # Constrained: beat 9 can't come closer than 0.25 s to beat 10 (unselected); the order stays.
        s.input(f'drag {P(lane_point(s, 4.25))} {P(lane_point(s, 6.5))}')
        after2 = samples(s)
        check(2, f'{o}: a big drag stops at the minimum distance to the unselected neighbours',
              after2[10] - after2[9] == MIN_DIST and after2[3] - after2[2] >= MIN_DIST and after2 == sorted(after2),
              f'gap {(after2[10] - after2[9]) / SR:.4f} s')
        s.input(f'drag {P(lane_point(s, 4.25))} {P(lane_point(s, 0.0))}')
        after3 = samples(s)
        check(2, f'{o}: dragging back stops at the beat before beat 1 (interleaved unselected beats keep the order)',
              (after3[1] - after3[0] == MIN_DIST or after3[3] - after3[2] == MIN_DIST or after3[5] - after3[4] == MIN_DIST)
              and after3 == sorted(after3) and len(set(after3)) == len(after3),
              f'{[round(x / SR, 3) for x in after3[:11]]}')
        # Click on empty lane clears.
        s.input(f'click {P(lane_point(s, 9.25))}')
        check(2, f'{o}: a click on empty lane clears the beat selection', sel(s) == [], str(sel(s)))
        # Drag a single beat without a selection.
        b = samples(s)
        p = mark_point(s, b[12])
        q = (p[0] + (10 if o == 'horizontal' else 0), p[1] + (10 if o == 'vertical' else 0))
        s.input(f'drag {P(p)} {P(q)}')
        a2 = samples(s)
        check(2, f'{o}: dragging a beat without a selection moves only it',
              [i for i in range(len(b)) if a2[i] != b[i]] == [12] and sel(s) == [], f'{(a2[12] - b[12]) / SR:.3f}')
        # Esc clears, Backspace deletes the selection.
        s.input(f'click {P(mark_point(s, b[14]))}', f'click {P(mark_point(s, b[15]))} cmd', 'key escape')
        check(2, f'{o}: Esc clears the beat selection', sel(s) == [], str(sel(s)))
        n0 = len(s.state['beats'])
        s.input(f'click {P(mark_point(s, b[14]))}', f'click {P(mark_point(s, b[15]))} cmd',
                f'move {P(lane_point(s, 9.25))}', 'key backspace')
        check(2, f'{o}: Backspace deletes the selected beats', len(s.state['beats']) == n0 - 2 and sel(s) == []
              and b[14] not in samples(s) and b[15] not in samples(s))
        s.quit()

def choose(s, title):
    """Chooses an item of the open context menu with the keyboard (Down × k, Return)."""
    s.dump()
    items = [m['title'] for m in s.state['beatMenu'] if not m['separator'] and not m['header'] and m['enabled']]
    if title not in items:
        return f'{title} not in {items}'
    s.input(*(['key down'] * (items.index(title) + 1)), 'key return')
    time.sleep(0.5)  # the menu sends the action after its fade-out
    s.dump()
    return 'chosen'


# 3. Context menu (mouse) and its actions
if run(3):
    for o in ORIENTATIONS:
        s = session(f'{o}_menu', o, even_beats())
        b = samples(s)
        s.input(f'rclick {P(mark_point(s, b[6]))}')
        s.snapshot('menu_single')
        out = [choose(s, 'Start bar (1st)')]
        check(3, f'{o}: right-click on an unselected beat selects it; its menu sets "Start bar"',
              out == ['chosen'] and sel(s) == [6] and s.state['beats'][6]['firstBeat'] == 'start'
              and read_side()[6]['firstBeat'] == 'start', f'{out} {sel(s)}')
        ok, d = layout_ok(s)
        check(3, f'{o}: beats 0–5 become pickup bars (0.3 0.4 / … ), beat 6 bar 1', ok and s.state['beats'][6]['barNumber'] == 1, d)
        titles = [(m['title'], m['checked']) for m in s.state['beatMenu'] if not m['separator']]
        check(3, f'{o}: single-beat menu', titles == [('Beat within bar', False), ('Auto (3rd)', False),
                                                      ('Start bar (1st)', True), ('Time signature…', False), ('Delete', False)],
              str(titles))
        s.command('beatsel 8'); s.dump()
        t8 = [m['title'] for m in s.state['beatMenu']]
        check(3, f'{o}: beat 8 counts as "Auto (3rd)"', 'Auto (3rd)' in t8, str(t8))
        # Multi menu with the mouse: right-click empty lane with a selection.
        s.input(f'click {P(mark_point(s, b[10]))}', f'click {P(mark_point(s, b[14]))} shift',
                f'rclick {P(lane_point(s, 9.25))}')
        s.snapshot('menu_multi')
        titles = [(m['title'], m['enabled']) for m in s.state['beatMenu'] if not m['separator']]
        check(3, f'{o}: multi-beat menu', titles == [('Subdivide…', True), ('Equalize beats within bars', True), ('Delete', True)],
              str(titles))
        out = [choose(s, 'Delete')]
        check(3, f'{o}: right-click on the lane opens the menu for the selection; Delete removes 5 beats',
              out == ['chosen'] and len(s.state['beats']) == len(b) - 5, f'{out} {len(s.state["beats"])}')
        s.quit()

# 4. Time signature dialog
if run(4):
    s = session('tsdialog', 'horizontal', even_beats())
    s.command('beatsel 4'); s.command('beatmenu Time signature…'); s.dump()
    d = s.state['timeSignatureDialog']
    check(4, 'opens prefilled with the inherited 4/4, "continue"', s.state['beatDialog'] == 'timeSignature'
          and d['sheetVisible'] and not d['change'] and (d['numerator'], d['denominator']) == ('4', 4), str(d))
    s.snapshot('ts_continue')
    s.command('tsdialog numerator 3'); s.dump()
    check(4, 'changing the numerator selects "change"', s.state['timeSignatureDialog']['change'])
    s.command('tsdialog mode continue'); s.dump()
    d = s.state['timeSignatureDialog']
    check(4, '"continue" resets to the inherited value', not d['change'] and (d['numerator'], d['denominator']) == ('4', 4), str(d))
    s.command('tsdialog denominator 8'); s.command('tsdialog numerator 6'); s.dump()
    check(4, 'changing the denominator selects "change"', s.state['timeSignatureDialog']['change'])
    s.snapshot('ts_change')
    s.command('tsdialog ok'); s.dump()
    bt = s.state['beats']
    check(4, 'OK sets 6/8 on beat 4: a bar start, 3 beats per bar; the first forced bar start, so the pickup counts in 6/8 too',
          bt[4]['timeSignature'] == '6/8' and bt[4]['beatInBar'] == 1 and bt[7]['beatInBar'] == 1 and bt[1]['effective'] == '6/8'
          and read_side()[4]['timeSignature'] == '6/8' and layout_ok(s)[0], layout_ok(s)[1])
    titles = [m['title'] for m in s.state['beatMenu']]
    check(4, 'the menu shows "Auto (1st)" for a beat with a time signature', 'Auto (1st)' in titles, str(titles))
    s.command('beatsel 4'); s.command('beatmenu Time signature…'); s.dump()
    d = s.state['timeSignatureDialog']
    check(4, 'reopened: "change", 6/8, inherited 4/4', d['change'] and (d['numerator'], d['denominator'], d['inherited']) == ('6', 8, '4/4'), str(d))
    s.command('tsdialog mode continue'); s.command('tsdialog ok'); s.dump()
    check(4, '"continue" + OK removes the signature', s.state['beats'][4]['timeSignature'] is None and layout_ok(s)[0])
    s.command('beatsel 9'); s.command('beatmenu Time signature…'); s.command('tsdialog numerator 5')
    s.command('tsdialog cancel'); s.dump()
    check(4, 'Cancel changes nothing', s.state['beats'][9]['timeSignature'] is None and s.state['beatDialog'] is None)
    # Inherited from an earlier change.
    s.command('beatsel 0'); s.command('beatmenu Time signature…'); s.command('tsdialog numerator 3'); s.command('tsdialog ok')
    s.command('beatsel 10'); s.command('beatmenu Time signature…'); s.dump()
    d = s.state['timeSignatureDialog']
    check(4, 'a later beat inherits 3/4', not d['change'] and (d['numerator'], d['denominator']) == ('3', 4), str(d))
    s.command('tsdialog cancel')
    s.quit()

# 5. Subdivide, Equalize
if run(5):
    s = session('subdivide', 'horizontal', even_beats())
    b = samples(s)
    s.command('beatsel 2,3,4,7,8'); s.command('beatmenu Subdivide…'); s.dump()
    d = s.state['subdivideDialog']
    check(5, 'Subdivide opens; max n keeps 0.25 s (0.5 s gaps: 2)', s.state['beatDialog'] == 'subdivide' and d['max'] == 2, str(d))
    s.snapshot('subdivide')
    s.command('subdivide 3'); s.dump()
    check(5, 'n above the maximum: OK disabled', not s.state['subdivideDialog']['okEnabled'])
    s.command('subdivide 2'); s.command('subdivide ok'); s.dump()
    got = samples(s)
    mids = [round((b[i] + b[i + 1]) / 2 + 1e-9) for i in (2, 3, 7)]
    check(5, 'n = 2: a beat in the middle of each gap between neighbouring selected beats (3 new)',
          len(got) == len(b) + 3 and all(m in got for m in mids) and layout_ok(s)[0], f'{len(got)}')
    s.quit()

    # Equalize: uneven beats, start bars at 0, 4, 8, 12.
    beats = []
    t = 0.5
    for k in range(16):
        beats.append({'sample': int(t * SR), 'firstBeat': 'start' if k % 4 == 0 else 'auto'})
        t += 0.5 + (0.12 if k % 4 == 1 else -0.04)
    s = session('equalize', 'horizontal', beats)
    b = samples(s)
    s.command('beatsel 0,4,5,8,13'); s.dump()
    titles = [(m['title'], m['enabled']) for m in s.state['beatMenu']]
    check(5, 'Equalize is enabled (bar 0–4 and 4–8 have both starts selected)', ('Equalize beats within bars', True) in titles)
    s.command('beatmenu Equalize beats within bars'); s.dump()
    got = samples(s)
    ok = all(abs(got[k] - (b[0] + (b[4] - b[0]) * k / 4)) <= 0.5 for k in range(1, 4)) \
        and all(abs(got[k] - (b[4] + (b[8] - b[4]) * (k - 4) / 4)) <= 0.5 for k in range(5, 8)) \
        and got[8:] == b[8:] and got[0] == b[0] and got[4] == b[4]
    check(5, 'the beats of bars 1 and 2 are spaced equally; bar starts and bar 3+ unchanged', ok)
    s.command('beatsel 1,2'); s.dump()
    titles = [(m['title'], m['enabled']) for m in s.state['beatMenu']]
    check(5, 'no bar start pair selected: Equalize disabled; Subdivide enabled',
          ('Equalize beats within bars', False) in titles and ('Subdivide…', True) in titles, str(titles))
    s.command('beatsel 1,3'); s.dump()
    titles = [(m['title'], m['enabled']) for m in s.state['beatMenu']]
    check(5, 'no neighbouring selected beats: Subdivide disabled', ('Subdivide…', False) in titles, str(titles))
    s.quit()

# 6. B places beats without a dialog
if run(6):
    s = session('bkey', 'horizontal', [])
    s.input(f'move {P(lane_point(s, 2.0))}', 'key b')
    s.input(f'move {P(lane_point(s, 3.0))}', 'key b shift')
    bt = s.state['beats']
    check(6, 'B / ⇧B place beats (auto / start) without a time signature dialog',
          [b['firstBeat'] for b in bt] == ['auto', 'start'] and s.state['beatDialog'] is None
          and not s.state['timeSignatureDialog']['sheetVisible'], str(bt))
    s.quit()

print(f'\n{sum(results)} of {len(results)} checks passed')
sys.exit(0 if all(results) else 1)
