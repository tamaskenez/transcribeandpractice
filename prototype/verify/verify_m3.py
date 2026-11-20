"""Checks milestone 3 acceptance criteria. Run from prototype/: python3 verify/verify_m3.py

Needs Accessibility (synthetic input) and Screen Recording (screenshots) permission for the
terminal. Don't touch the mouse or keyboard while it runs. Screenshots: verify/out/m3/*.png.
"""
import json, os, subprocess, sys
import numpy as np

sys.path.insert(0, os.path.dirname(__file__))
from gen_test_audio_m2 import signals, SR  # noqa: E402
from m3session import OUT, BIN, Session, build_driver  # noqa: E402
import waveref  # noqa: E402

AUDIO = f'{OUT}/audio'
MONO, STEREO = f'{AUDIO}/wave_mono.wav', f'{AUDIO}/wave_stereo.wav'
D = 4.0
MIN_VIEW = 0.1      # maximum zoom: shortest visible range
M = MIN_VIEW / 2    # the view may extend this far beyond both ends of the file
FULL = (-M, D + M)
results = []


def check(criterion, desc, ok, detail=''):
    results.append(bool(ok))
    print(f"{'PASS' if ok else 'FAIL'}  [{criterion}] {desc}" + (f'  -- {detail}' if detail and not ok else ''))


def close(a, b, tol):
    if a is None or b is None:
        return a is None and b is None
    return all(abs(x - y) <= tol for x, y in zip(a, b))


def P(xy):
    return f'{xy[0]:.2f} {xy[1]:.2f}'


def run_app(name, opens=(), extra=(), snapshot=False):
    dump = f'{OUT}/{name}.json'
    args = [BIN] + [f'--open={os.path.abspath(o)}' for o in opens] + list(extra)
    args += [f'--dump-state={dump}', '--quit']
    if snapshot:
        args.append(f'--snapshot={OUT}/{name}.png')
    if os.path.exists(dump):
        os.remove(dump)
    subprocess.run(['perl', '-e', 'alarm 30; exec @ARGV'] + args, check=True)
    return json.load(open(dump))


def reference_points(mono, w, h, orientation, start, end):
    return waveref.reference_points(mono, SR, w, h, orientation, start, end)


# 1. Builds, earlier milestones (verify_m2 also runs build.sh, the CMake build and verify_m1)
r = subprocess.run([sys.executable, 'verify/verify_m2.py'], capture_output=True, text=True)
fails = [l for l in r.stdout.splitlines() if l.startswith('FAIL')]
check(1, 'verify_m2.py passes (build.sh, CMake build, verify_m1)', r.returncode == 0 and not fails,
      '\n'.join(fails) or r.stdout[-300:] + r.stderr[-300:])
m1 = subprocess.run([sys.executable, 'verify/verify_m1.py'], capture_output=True, text=True)
check(1, 'verify_m1.py passes', m1.returncode == 0, m1.stdout[-300:])
os.makedirs(OUT, exist_ok=True)
subprocess.run([sys.executable, 'verify/gen_test_audio_m2.py', AUDIO], check=True, capture_output=True)
build_driver()
mono = signals()['wave_mono.wav'][:, 0].astype(np.float32)

# 2. Toolbar after load
s = Session('c2', [MONO])
labels = [i['label'] for i in s.state['toolbar']['items']]
st = s.state
ax = [s.input(f'enabled {s.proc.pid} {t}') for t in ('Zoom Out Full', 'Zoom to Selection')]
check(2, 'toolbar: Zoom Out Full, Zoom to Selection, selection indicator, orientation toggle',
      # (milestone 4 added Follow Playhead, milestone 6 Show Beats, before the orientation toggle)
      labels[:2] == ['Zoom Out Full', 'Zoom to Selection'] and len(labels) in (4, 5, 6) and labels[-1] == 'Time Orientation',
      labels)
check(2, 'after load: whole file plus margins (-0.05–4.05 s), no selection, indicator "–", both buttons disabled (dump and AX)',
      close(s.view(), FULL, 1e-9) and s.sel() is None and st['selectionText'] == '–'
      and st['buttons'] == {'zoomOutFull': False, 'zoomToSelection': False} and ax == [['false'], ['false']],
      f"{s.view()} {s.sel()} {st['selectionText']} {st['buttons']} {ax}")
s.quit()

for orientation in ['horizontal', 'vertical']:
    o = orientation[0]
    # 3. --view=1,2: polylines, scrollbar, screenshot
    st = run_app(f'c3_{orientation}', [MONO], [f'--orientation={orientation}', '--view=1.0,2.0'], snapshot=True)
    errs = []
    for pane in ['navigator', 'main']:
        w = st['waveforms'][pane]
        ref = reference_points(mono, w['size']['width'], w['size']['height'], orientation, 1.0, 2.0)
        got = np.array(w['points'])
        err = np.abs(got - ref).max() if got.shape == ref.shape else float('inf')
        if err > 0.5:
            errs.append(f'{pane} error {err}')
    check(3, f'{orientation}: --view=1,2 polylines match the reference in both panes', not errs, errs)
    sb, pf = st['scrollbar'], st['paneFrames']
    nav, bar = pf['navigator'], pf['scrollbar']
    along = 'x' if o == 'h' else 'y'
    extent = 'width' if o == 'h' else 'height'
    kr = sb['knobRect']
    knob_pos = kr[along] / sb['size'][extent]
    if o == 'h':
        edge_ok = abs(bar['y'] + bar['height'] - (nav['y'] + nav['height'])) < 0.5 and bar['width'] == nav['width']
    else:
        edge_ok = abs(bar['x'] + bar['width'] - (nav['x'] + nav['width'])) < 0.5 and bar['height'] == nav['height']
    check(3, f'{orientation}: scrollbar along the navigator time axis, legacy style, knob at (1+0.05)/4.1 with proportion 1/4.1',
          edge_ok and sb['vertical'] == (o == 'v') and sb['style'] == 'legacy' and sb['enabled']
          and abs(sb['knobProportion'] - 1 / (D + 2 * M)) < 1e-6
          and abs(sb['value'] - (1 + M) / (D + 2 * M - 1)) < 1e-6
          and abs(knob_pos - (1 + M) / (D + 2 * M)) < 0.02 and st['buttons']['zoomOutFull'],
          f'{sb} {bar} {nav} knob_pos {knob_pos:.3f}')

# 3b. Margins: no waveform points outside the file
for orientation in ['horizontal', 'vertical']:
    st = run_app(f'c3b_{orientation}', [MONO], [f'--orientation={orientation}', '--view=-0.05,0.95'], snapshot=True)
    w = st['waveforms']['main']
    ref = reference_points(mono, w['size']['width'], w['size']['height'], orientation, -0.05, 0.95)
    got = np.array(w['points'])
    err = np.abs(got - ref).max() if got.shape == ref.shape else float('inf')
    first = got[0][0 if orientation == 'horizontal' else 1]
    L = w['size']['width' if orientation == 'horizontal' else 'height']
    check(3, f'{orientation}: view -0.05–0.95: waveform starts at 5% of the pane (none before the file start)',
          err <= 0.5 and abs(first - 0.05 * L) <= 1, f'error {err}, first point at {first} of {L}')

# 4. Limits via hooks
for args, want in [('1.0,1.0002', (1.0001 - 0.05, 1.0001 + 0.05)), ('-1,10', FULL), ('3.5,4.5', (3.0 + M, 4.0 + M)),
                   ('-0.5,0.5', (-M, 1 - M))]:
    st = run_app('c4', [MONO], [f'--view={args}'])
    v = (st['view']['start'], st['view']['end'])
    check(4, f'--view={args} gives {want[0]:.4f}–{want[1]:.4f}', close(v, want, 1e-9), v)

for orientation in ['horizontal', 'vertical']:
    s = Session(f'in_{orientation}', [MONO], orientation)
    o = orientation[0]
    pid = s.proc.pid
    L = s.length('main')
    tol = D / L  # one point at view 0–4
    s.command('view 0,4'); s.dump()

    # 5. Plain drag selection
    s.input(f'drag {P(s.at("main", .25))} {P(s.at("main", .75))}')
    sel_main, text = s.sel(), s.state['selectionText']
    zts = s.state['buttons']['zoomToSelection']
    s.snapshot('selection')
    s.input('key escape')
    s.input(f'drag {P(s.at("main", .75))} {P(s.at("main", .25))}')
    sel_rev = s.sel()
    s.input('key escape')
    # Escape left the playhead (draggable since the milestone 4 review) at 1.0 = 25%; move it away.
    s.command('playhead 0'); s.dump()
    s.input(f'drag {P(s.at("navigator", .25))} {P(s.at("navigator", .75))}')
    sel_nav = s.sel()
    tol_nav = D / s.length('navigator')
    check(5, f'{orientation}: drag 25%→75% selects 1–3 s (main, reverse, navigator)',
          close(sel_main, (1, 3), tol) and close(sel_rev, (1, 3), tol) and close(sel_nav, (1, 3), tol_nav),
          f'{sel_main} {sel_rev} {sel_nav}')
    check(5, f'{orientation}: indicator "0:01.000 – 0:03.000 (0:02.000)", Zoom to Selection enabled',
          text == '0:01.000 – 0:03.000 (0:02.000)' and zts, f'{text!r} {zts}')
    s.command('view 1,2'); s.command('select'); s.dump()
    s.input(f'drag {P(s.at("main", .5))} {P(s.at("main", 1.2))}')
    check(5, f'{orientation}: drag leaving the pane is limited to the visible range (1.5–2.0)',
          close(s.sel(), (1.5, 2.0), 1 / L), s.sel())
    s.command('view 0,4'); s.dump()

    # 6. Shift-click / shift-drag
    s.command('select 1,3'); s.dump()
    s.input(f'click {P(s.at("main", .9))} shift')
    a = s.sel()
    s.input(f'click {P(s.at("main", .1))} shift')
    b = s.sel()
    s.input('key escape')
    s.input(f'drag {P(s.at("main", .25))} {P(s.at("main", .75))} shift')
    c = s.sel()
    check(6, f'{orientation}: shift-click 90% → 1.0–3.6, then 10% → 0.4–3.6; shift-drag without selection = drag',
          close(a, (1, 3.6), tol) and close(b, (0.4, 3.6), tol) and close(c, (1, 3), tol), f'{a} {b} {c}')

    # 7. Clearing
    s.input(f'click {P(s.at("main", .5))}')
    a = s.sel()
    s.command('select 1,3'); s.dump()
    s.input('key escape')
    check(7, f'{orientation}: click without drag clears; Escape clears', a is None and s.sel() is None, f'{a} {s.sel()}')

    # 8. Scroll pans
    def scrolled(dx, dy, view=(1, 2), mods='-'):
        s.command(f'view {view[0]},{view[1]}'); s.dump()
        s.input(f'scroll {P(s.at("main", .5))} {dx} {dy} {mods}')
        return s.view()
    sec = 1 / L  # seconds per point at view 1–2
    r1 = scrolled(0, -50)
    r2 = scrolled(-50, 0)
    if o == 'h':
        ok = close(r1, (1 + 50 * sec, 2 + 50 * sec), 1e-6) and close(r2, (1 + 50 * sec, 2 + 50 * sec), 1e-6)
    else:
        ok = close(r1, (1 + 50 * sec, 2 + 50 * sec), 1e-6) and close(r2, (1, 2), 1e-9)
    r3 = scrolled(0, 200, (0, 1))
    r4 = scrolled(0, -200, (3, 4))
    check(8, f'{orientation}: scrolling pans by the scrolled distance ({"both axes" if o == "h" else "vertical axis only"}); stops 50 ms beyond the ends',
          ok and close(r3, (-M, 1 - M), 1e-9) and close(r4, (3 + M, 4 + M), 1e-9), f'{r1} {r2} {r3} {r4}')

    # 9. ⌘ + scroll along the time axis zooms time around the pointer
    def tscroll(d):  # (dx, dy) of a scroll of d points along the time axis
        return f'{d} 0' if o == 'h' else f'0 {d}'
    s.command('view 1,2'); s.dump()
    anchor = 1 + .3
    s.input(f'scroll {P(s.at("main", .3))} {tscroll(100)} cmd')
    v1 = s.view()
    t_after = v1[0] + .3 * (v1[1] - v1[0])
    s.input(f'scroll {P(s.at("main", .3))} {tscroll(-100)} cmd')
    v2 = s.view()
    zoomed_in = v1[1] - v1[0] < 0.5 and v1[1] - v1[0] >= MIN_VIEW - 1e-9 and abs(t_after - anchor) <= (v1[1] - v1[0]) / L
    zoomed_out = abs(v2[0] - 1) < 1e-6 and abs(v2[1] - 2) < 1e-6
    s.input(*[f'scroll {P(s.at("main", .3))} {tscroll(300)} cmd'] * 12)
    vmax = s.view()
    s.input(*[f'scroll {P(s.at("main", .3))} {tscroll(-300)} cmd'] * 12)
    vmin = s.view()
    check(9, f'{orientation}: ⌘+scroll along the time axis zooms time in/out around the pointer (amplitude unchanged); stops at 100 ms and the whole file plus margins',
          zoomed_in and zoomed_out and abs(vmax[1] - vmax[0] - MIN_VIEW) < 1e-9 and close(vmin, FULL, 1e-9)
          and s.state['amplitudeZoomDB'] == 0,
          f'{v1} anchor@{t_after:.6f} {v2} {vmax} {vmin}')

    # 10. Pinch
    s.command('view 1,2'); s.dump()
    s.input(f'magnify {P(s.at("main", .3))} 0.5')
    v1 = s.view()
    t_after = v1[0] + .3 * (v1[1] - v1[0])
    s.input(f'magnify {P(s.at("main", .3))} -0.5')
    v2 = s.view()
    check(10, f'{orientation}: pinch zooms in/out around the pointer (synthetic magnify events)',
          v1[1] - v1[0] < 0.7 and abs(t_after - 1.3) <= (v1[1] - v1[0]) / L and v2[1] - v2[0] > v1[1] - v1[0],
          f'{v1} anchor@{t_after:.6f} {v2}')

    # 11. Option-drag / middle-drag pan
    res = []
    for mods, button in [('option', 'left'), ('-', 'middle')]:
        s.command('view 1,2'); s.dump()
        s.input(f'drag {P(s.at("main", .5))} {P(s.at("main", .3))} {mods} {button}')
        res.append(s.view())
    s.command('view 0,1'); s.dump()
    s.input(f'drag {P(s.at("main", .3))} {P(s.at("main", .8))} option')
    end_stop = s.view()
    check(11, f'{orientation}: option-drag and middle-drag move the grabbed time with the pointer; stop at the ends',
          all(close(v, (1.2, 2.2), 1 / L) for v in res) and close(end_stop, (-M, 1 - M), 1e-9) and s.sel() is None,
          f'{res} {end_stop}')

    # 12. Scrollbar
    s.command('view 1,2'); s.dump()
    sb = s.state['screenFrames']['scrollbar']
    along, extent = ('x', 'width') if o == 'h' else ('y', 'height')
    def bar_at(f):
        p = dict(x=sb['x'] + sb['width'] / 2, y=sb['y'] + sb['height'] / 2)
        p[along] = sb[along] + f * sb[extent]
        return p['x'], p['y']
    s.input(f'drag {P(bar_at(.375))} {P(bar_at(.475))}')
    v_drag = s.view()
    s.command('view 1,2'); s.dump()
    s.input(f'click {P(bar_at(.9))}')
    v_click = s.view()
    check(12, f'{orientation}: dragging the knob by 10% of the track pans ~0.41 s; clicking the track pans',
          abs(v_drag[0] - (1 + 0.1 * (D + 2 * M))) < 0.03 and abs(v_drag[1] - v_drag[0] - 1) < 1e-9 and v_click[0] > 1.5,
          f'{v_drag} {v_click}')

    # 13. Toolbar buttons via Accessibility
    s.command('view 0,4'); s.command('select 1,3'); s.dump()
    en = s.input(f'enabled {pid} Zoom to Selection')
    pr = s.input(f'press {pid} Zoom to Selection')
    v1 = s.view()
    en2 = s.input(f'enabled {pid} Zoom Out Full')
    s.input(f'press {pid} Zoom Out Full')
    v2 = s.view()
    en3 = s.input(f'enabled {pid} Zoom Out Full')
    check(13, f'{orientation}: Zoom to Selection shows 1–3, then Zoom Out Full the whole file (pressed via AX)',
          en == ['true'] and pr == ['pressed'] and close(v1, (1, 3), 1e-9) and en2 == ['true']
          and close(v2, FULL, 1e-9) and en3 == ['false'], f'{en} {pr} {v1} {en2} {v2} {en3}')

    # 14. Resize, divider drag, orientation switch keep range and selection
    s.command('view 1,2'); s.command('select 1.2,1.5'); s.dump()
    s.command('resize 800,600'); s.dump()
    after_resize = (s.view(), s.sel(), s.state['contentSize'])
    c, dv = s.state['screenFrames']['content'], s.state['paneFrames']['divider']
    frac0 = s.state['navigatorFraction']
    mid = (c['x'] + dv['x'] + dv['width'] / 2, c['y'] + dv['y'] + dv['height'] / 2)
    to = (mid[0], mid[1] + 60) if o == 'h' else (mid[0] + 60, mid[1])
    s.input(f'drag {P(mid)} {P(to)}')
    after_divider = (s.view(), s.sel(), s.state['navigatorFraction'])
    s.command(f'orientation {"vertical" if o == "h" else "horizontal"}'); s.dump()
    after_orient = (s.view(), s.sel())
    want = ((1, 2), (1.2, 1.5))
    check(14, f'{orientation}: resize, divider drag and orientation switch keep view and selection',
          after_resize[:2] == want and after_resize[2] == {'width': 800, 'height': 600}
          and after_divider[:2] == want and after_divider[2] > frac0 + 0.05 and after_orient == want,
          f'{after_resize} {after_divider} (fraction before {frac0}) {after_orient}')

    # 15. Opening another file resets view and selection
    s.command(f'orientation {orientation}'); s.command('view 1,2'); s.command('select 1.2,1.5')
    s.command(f'open {os.path.abspath(STEREO)}'); s.dump()
    check(15, f'{orientation}: opening a second file shows the whole file, no selection',
          s.state['loaded']['fileName'] == 'wave_stereo.wav' and close(s.view(), FULL, 1e-9) and s.sel() is None,
          f'{s.view()} {s.sel()}')
    # 16. Amplitude zoom: ⌘ + scroll across the time axis
    def ascroll(d):
        return f'0 {d}' if o == 'h' else f'{d} 0'
    s.command(f'open {os.path.abspath(MONO)}')  # criterion 15 left the stereo file open
    s.command('view 1,2'); s.command('amplitude 0'); s.dump()
    s.input(f'scroll {P(s.at("main", .3))} {ascroll(100)} cmd')
    a1, v1 = s.state['amplitudeZoomDB'], s.view()
    s.input(f'scroll {P(s.at("main", .3))} {ascroll(-50)} cmd')
    a2 = s.state['amplitudeZoomDB']
    s.input(*[f'scroll {P(s.at("main", .3))} {ascroll(300)} cmd'] * 4)
    amax = s.state['amplitudeZoomDB']
    s.input(*[f'scroll {P(s.at("main", .3))} {ascroll(-300)} cmd'] * 4)
    amin = s.state['amplitudeZoomDB']
    db = 20 * np.log10(np.e)  # 100 points = factor e
    check(16, f'{orientation}: ⌘+scroll across the time axis zooms amplitude (time view unchanged); 0–60 dB',
          abs(a1 - db) < 1e-6 and v1 == (1, 2) and abs(a2 - db / 2) < 1e-6 and amax == 60 and amin == 0,
          f'{a1} {v1} {a2} {amax} {amin}')
    s.command('amplitude 20'); s.dump()
    s.snapshot('amp20')
    errs = []
    for pane in ['navigator', 'main']:
        w = s.state['waveforms'][pane]
        ref = waveref.reference_points(mono, SR, w['size']['width'], w['size']['height'], orientation, 1, 2, 10.0)
        got = np.array(w['points'])
        err = np.abs(got - ref).max() if got.shape == ref.shape else float('inf')
        if err > 0.5:
            errs.append(f'{pane} {err}')
    check(16, f'{orientation}: at +20 dB both panes draw the samples ×10 (polyline reference)', not errs, errs)
    en = s.input(f'enabled {pid} Zoom Out Full')
    s.input(f'press {pid} Zoom Out Full')
    a_full = s.state['amplitudeZoomDB']
    s.command('amplitude 20'); s.command(f'open {os.path.abspath(MONO)}'); s.dump()
    check(16, f'{orientation}: Zoom Out Full and opening a file reset the amplitude zoom to 0 dB',
          en == ['true'] and a_full == 0 and s.state['amplitudeZoomDB'] == 0, f'{en} {a_full} {s.state["amplitudeZoomDB"]}')

    # 17. Cursor over the selection
    s.command('view 0,4'); s.command('select 1,3'); s.dump()
    edge_cursor = 'columnResize' if o == 'h' else 'rowResize'
    cur = {}
    for label, f in [('start edge', .25), ('end edge', .75), ('inside', .5), ('outside', .1), ('start edge+3', .25 + 3 / L)]:
        s.input(f'move {P(s.at("main", f))}', 'sleep 50')
        cur[label] = (s.state['currentCursor'], s.state['waveforms']['main']['cursor'])
    want = {'start edge': edge_cursor, 'end edge': edge_cursor, 'inside': 'openHand', 'outside': 'arrow',
            'start edge+3': edge_cursor}
    check(17, f'{orientation}: cursor: {edge_cursor} on the selection edges (±4 pt), open hand inside, arrow outside',
          all(cur[k] == (v, v) for k, v in want.items()), cur)

    # 18. Dragging an edge / the whole selection
    s.input(f'drag {P(s.at("main", .75))} {P(s.at("main", .9))}')
    e1 = s.sel()
    s.input(f'drag {P(s.at("main", .25))} {P(s.at("main", .1))}')
    e2 = s.sel()
    s.command('select 1,3'); s.dump()
    s.input(f'drag {P(s.at("main", .75))} {P(s.at("main", .1))}')
    e3 = s.sel()
    check(18, f'{orientation}: dragging the end edge 75%→90% gives 1–3.6, the start edge 25%→10% 0.4–3.6; '
          'dragging an edge past the other flips (0.4–1)',
          close(e1, (1, 3.6), tol) and close(e2, (0.4, 3.6), tol) and close(e3, (0.4, 1), tol), f'{e1} {e2} {e3}')
    s.command('select 1,3'); s.dump()
    s.input(f'drag {P(s.at("main", .5))} {P(s.at("main", .6))}')
    m1 = s.sel()
    s.input(f'drag {P(s.at("main", .6))} {P(s.at("main", 1.2))}')
    m2 = s.sel()
    s.input(f'drag {P(s.at("navigator", .75))} {P(s.at("navigator", .25))}')
    m3 = s.sel()
    tol_nav = D / s.length('navigator')
    check(18, f'{orientation}: dragging inside moves the selection (1–3 → 1.4–3.4), stops at the file end (2–4); also in the navigator',
          close(m1, (1.4, 3.4), tol) and close(m2, (2, 4), 1e-9) and close(m3, (0, 2), tol_nav), f'{m1} {m2} {m3}')
    s.command('select 1,3'); s.dump()
    s.input(f'click {P(s.at("main", .5))}')
    check(18, f'{orientation}: a click inside the selection (no drag) still clears it', s.sel() is None, s.sel())

    s.command('resize 1000,700')  # the window frame is restored on the next launch
    s.quit()

print(f'\n{sum(results)}/{len(results)} checks passed')
sys.exit(0 if all(results) else 1)
