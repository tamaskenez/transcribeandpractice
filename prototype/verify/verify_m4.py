"""Checks milestone 4 acceptance criteria. Run from prototype/: python3 verify/verify_m4.py

Plays audio (audible). Needs Accessibility and Screen Recording permission for the terminal.
Don't touch the mouse or keyboard while it runs. Screenshots: verify/out/m4/*.png.
"""
import os, subprocess, sys, time
import numpy as np

sys.path.insert(0, os.path.dirname(__file__))
import m4util  # noqa: E402
from m4util import *  # noqa: E402,F401,F403
from m4util import check, P, pb, wait_until, wait_playhead, Recording, segments_ok, looped, results  # noqa: E402

# 1. Earlier milestones (verify_m3 also runs verify_m2, verify_m1, build.sh and the CMake build)
if os.environ.get('SKIP_EARLIER'):  # development shortcut
    subprocess.run(['./build.sh'], check=True, capture_output=True)
else:
    r = subprocess.run([sys.executable, 'verify/verify_m3.py'], capture_output=True, text=True)
    fails = [l for l in r.stdout.splitlines() if l.startswith('FAIL')]
    check(1, 'verify_m3.py passes (with verify_m2, verify_m1, build.sh, CMake build)', r.returncode == 0 and not fails,
          '\n'.join(fails) or r.stdout[-300:] + r.stderr[-300:])
    r = subprocess.run([sys.executable, 'verify/verify_m1.py'], capture_output=True, text=True)
    check(1, 'verify_m1.py passes', r.returncode == 0, r.stdout[-300:])
os.makedirs(OUT, exist_ok=True)
subprocess.run([sys.executable, 'verify/gen_test_audio_m4.py', AUDIO], check=True, capture_output=True)
m4util.X = X = noise()
build_driver()
subprocess.run(['defaults', 'delete', DOMAIN], capture_output=True)

# 2. Transport and toolbar
s = Session('c2', [NOISE])
pid = s.proc.pid
labels = [i['label'] for i in s.state['toolbar']['items']]
ax = {t: s.input(f'enabled {pid} {t}') for t in ['Rewind and Play', 'Play or Stop', 'Play Again', 'Loop', 'Follow Playhead']}
p = pb(s)
s.snapshot('transport')
check(2, 'transport buttons (rewind-and-play, play-or-stop, play-again, loop) and toolbar follow button exist and are enabled',
      all(v == ['true'] for v in ax.values()) and 'Follow Playhead' in labels, f'{ax} {labels}')
check(2, 'after load: playhead 0, not playing, loop and follow off (fresh defaults)',
      p['playhead'] == 0 and not p['playing'] and not p['loop'] and not p['follow'], p)

# 4. Play-or-stop from 1.0
s.command('playhead 1.0'); s.dump()
rec = Recording(s, 'c4')
s.input('key space')
dumps = []
for _ in range(10):
    time.sleep(0.1)
    s.dump()
    dumps.append(dict(pb(s)))
s.input('key space')
after = pb(s)
r4 = rec.stop()
ok, detail = segments_ok(r4, [(1.0, None)])
check(4, f'rendered audio = file samples from 1.0 s on, both channels, sample-exact ({len(r4) / SR:.2f} s)', ok, detail)
ts = np.array([d['uptime'] for d in dumps])
ph = np.array([d['playhead'] for d in dumps])
slope = np.polyfit(ts, ph, 1)[0]
lags = [(d['startFrame'] + d['renderedFrames'] - d['corePlayheadFrame']) - d['latencyFrames'] for d in dumps]
buf = dumps[-1]['lastCallbackFrames']
updates_ok = all(d['callbackCount'] - dumps[0]['callbackCount'] - (d['playheadUpdates'] - dumps[0]['playheadUpdates']) == 0
                 for d in dumps)
check(4, f'playhead advances at real-time rate (slope {slope:.4f}); lags the rendered position by the latency '
      f'({dumps[0]["latencySeconds"] * 1000:.1f} ms) + at most one buffer; one update per callback',
      abs(slope - 1) <= 0.02 and all(0 <= l <= buf for l in lags) and updates_ok and dumps[-1]['playing'],
      f'slope {slope} lags {lags} buffer {buf} updates_ok {updates_ok}')
last = dumps[-1]
check(4, 'Space stops; the playhead stays where playback was (within the dump interval)',
      not after['playing'] and last['playhead'] <= after['playhead'] <= last['playhead'] + (after['uptime'] - last['uptime']) + 0.05,
      f'{last["playhead"]} -> {after["playhead"]} in {after["uptime"] - last["uptime"]:.3f} s')

# 3. I/O buffer (the device is configured when playback first starts)
p = pb(s)
dur = p['ioBufferFrames'] / p['deviceSampleRate']
k = dur * p['refreshRate']
mult_err = abs(k - round(k)) / p['refreshRate'] * p['deviceSampleRate'] if p['refreshRate'] else 0
check(3, f'I/O buffer {p["ioBufferFrames"]} frames at {p["deviceSampleRate"]:.0f} Hz = {dur * 1000:.1f} ms: in 30–50 ms, '
      f'a multiple of the {p["refreshRate"]:.0f} Hz refresh period',
      0.03 - 1e-6 <= dur <= 0.05 + 1e-6 and mult_err <= 1, f'{p} multiple error {mult_err:.2f} samples')

# 5. No selection: stops at the file end
s.command('playhead 9.5'); s.dump()
rec = Recording(s, 'c5')
s.input('key space')
ended = wait_until(s, lambda p: not p['playing'], 3)
r5 = rec.stop()
ok, detail = segments_ok(r5, [(9.5, D)])
check(5, 'no selection: stops at the file end, playhead back at 0, rendered 9.5 s – last sample',
      ended and pb(s)['playhead'] == 0 and ok, f'{pb(s)["playhead"]} {detail}')

# 6. Selection 2–3, loop off, started at the selection start: stops at 3.0
s.command('playhead 2.0'); s.command('select 2,3'); s.command('loop off'); s.dump()
rec = Recording(s, 'c6')
s.input('key space')
ended = wait_until(s, lambda p: not p['playing'], 3)
r6 = rec.stop()
ok, detail = segments_ok(r6, [(2.0, 3.0)])
check(6, 'selection 2–3, loop off, started at 2.0: stops at 3.0, playhead at 3.0 (the selection end), rendered 2.0–3.0 exactly',
      ended and abs(pb(s)['playhead'] - 3.0) < 1e-9 and ok, f'{pb(s)["playhead"]} {detail}')

# 7. Loop on
s.command('loop on'); s.dump()
rec = Recording(s, 'c7')
s.input('key left')
time.sleep(2.5)
s.input('key space')
r7 = rec.stop()
ok, detail = segments_ok(r7, looped(2, 2, 3))
check(7, f'loop on: rendered 2–3, 2–3, 2–… ({len(r7) / SR:.2f} s) with no gap or repeated sample', ok and len(r7) > 2.3 * SR, detail)

# 8. When the selection end doesn't stop or loop
s.command('loop off'); s.command('view 0,10'); s.dump()
s.input('key left')
wait_playhead(s, 2.4)
s.input('key space')
s.input('key space')
a = wait_playhead(s, 3.3, 3)
s.input('key space')
s.command('playhead 4.0'); s.command('select 2,3'); s.dump()
s.input('key space')
b = wait_playhead(s, 5.0, 3)
s.input('key space')
check(8, 'loop off: stop + continue inside the selection plays through its end; starting outside (4.0) ignores it', a and b, f'{a} {b}')

s.command('select 2,3'); s.dump()
rec = Recording(s, 'c8_move')
s.input('key left')
wait_playhead(s, 2.1)
s.input(f'drag {P(s.at("main", .25))} {P(s.at("main", .30))}')  # move the selection 2–3 to 2.5–3.5
sel_moved = s.sel()
ended = wait_until(s, lambda p: not p['playing'], 3)
r8 = rec.stop()
ok, detail = segments_ok(r8, [(2.0, 3.5)])
check(8, 'started at the selection start, selection moved to 2.5–3.5 while playing: stops at 3.5, playhead at 3.5',
      sel_moved == (2.5, 3.5) and ended and abs(pb(s)['playhead'] - 3.5) < 1e-9 and ok, f'{sel_moved} {pb(s)["playhead"]} {detail}')

s.command('select 2,3'); s.dump()
s.input('key left')
wait_playhead(s, 2.2)
s.input(f'drag {P(s.at("main", .30))} {P(s.at("main", .21))}')  # end edge 3.0 -> 2.1, behind the playhead
sel_edge = s.sel()
c = wait_playhead(s, 4.0, 3)
s.input('key space')
check(8, 'end edge dragged before the play position (to 2.1): no stop, plays on past 4.0',
      c and abs(sel_edge[1] - 2.1) < 0.02, f'{c} {sel_edge}')

s.command('loop on'); s.command('playhead 4.0'); s.command('select 2,3'); s.dump()
s.input('key space')
d = wait_playhead(s, 5.0, 3)
s.input('key space')
s.command('select 2,3'); s.dump()
s.input('key left')
wait_playhead(s, 2.2)
s.input(f'drag {P(s.at("main", .30))} {P(s.at("main", .21))}')
e = wait_playhead(s, 3.4, 3)
s.input('key space')
s.command('loop off')
check(8, 'loop on: starting outside (4.0) ignores the selection; end moved before the play position: no loop back',
      d and e, f'{d} {e}')

# 9. Rewind-and-play / play-again
s.command('playhead 5.0'); s.command('select 2,3'); s.dump()
s.input('key space')
time.sleep(0.3)
s.input('key left')
r_sel = (pb(s)['lastStart'], pb(s)['playing'], pb(s)['playhead'])
s.input(f'press {pid} Rewind and Play')
r_btn = (pb(s)['lastStart'], pb(s)['playing'])
s.input('key space')
s.input(f'click {P(s.at("main", .6))}')  # clears the selection, playhead 6.0
s.input('key left')
r_click = (pb(s)['lastStart'], pb(s)['playing'])
time.sleep(0.5)
s.input('key right')
r_again = (pb(s)['lastStart'], pb(s)['playing'], pb(s)['playhead'])
time.sleep(0.3)
s.input(f'press {pid} Play Again')
r_again_btn = (pb(s)['lastStart'], pb(s)['playhead'])
s.input('key space')
s.command(f'open {os.path.abspath(NOISE)}'); s.dump()
s.input('key left')
r_open = (pb(s)['lastStart'], pb(s)['playing'])
s.input('key space')
tol = 10 / s.length('main')
check(9, 'rewind-and-play (← and button): restarts at the selection start (2.0); with no selection at the clicked 6.0; '
      'after opening a file at 0',
      r_sel[0] == 2.0 and r_sel[1] and r_sel[2] < 2.3 and r_btn == (2.0, True) and abs(r_click[0] - 6.0) <= tol
      and r_click[1] and r_open == (0, True), f'{r_sel} {r_btn} {r_click} {r_open}')
check(9, 'play-again (→ and button): restarts at the last start',
      r_again[0] == r_click[0] and r_again[1] and r_again[2] - r_click[0] < 0.25
      and r_again_btn[0] == r_click[0] and r_again_btn[1] - r_click[0] < 0.25, f'{r_again} {r_again_btn}')
s.command('resize 1000,700')
s.quit()

for orientation in ['horizontal', 'vertical']:
    s = Session(f'mouse_{orientation}', [NOISE], orientation)
    s.command('view 0,10'); s.command('loop off'); s.dump()
    L = s.length('main')
    tol = 10 / L

    # 10. Mouse during playback
    s.input('key space')
    time.sleep(0.3)
    s.input(f'click {P(s.at("main", .5))}')
    p = pb(s)
    a = (not p['playing'], abs(p['playhead'] - 5.0) <= tol, abs(p['rewindPoint'] - 5.0) <= tol)
    s.input('key space')
    time.sleep(0.3)
    s.input(f'drag {P(s.at("main", .2))} {P(s.at("main", .3))}')
    p = pb(s)
    b = (not p['playing'], abs(p['playhead'] - 2.0) <= tol, s.sel() is not None)
    s.command('select 2,3'); s.dump()
    s.input('key left')
    time.sleep(0.3)
    s.input('key escape')
    p = pb(s)
    c = (not p['playing'], p['playhead'] == 2.0, s.sel() is None)
    check(10, f'{orientation}: during playback a click stops it with playhead/rewind point at the click; a new selection '
          'drag stops it with the playhead at the selection start; Escape stops it with the playhead at the former start',
          all(a) and all(b) and all(c), f'{a} {b} {c}')

    s.command('loop on'); s.command('select 2,3'); s.dump()
    rec = Recording(s, f'c10_edge_{orientation}')
    s.input('key left')
    wait_playhead(s, 2.3)
    s.input(f'drag {P(s.at("main", .30))} {P(s.at("main", .40))}')  # end edge 3 -> 4
    sel1 = s.sel()
    playing1 = pb(s)['playing']
    time.sleep(2.2)
    s.input('key space')
    r_edge = rec.stop()
    ok1, d1 = segments_ok(r_edge, looped(2, 2, 4))
    s.command('select 2,3'); s.dump()
    rec = Recording(s, f'c10_move_{orientation}')
    s.input('key left')
    wait_playhead(s, 2.3)
    s.input(f'drag {P(s.at("main", .25))} {P(s.at("main", .30))}')  # move to 2.5–3.5
    sel2 = s.sel()
    playing2 = pb(s)['playing']
    time.sleep(1.5)
    s.input('key space')
    r_move = rec.stop()
    ok2, d2 = segments_ok(r_move, looped(2, 2.5, 3.5))
    s.command('loop off')
    check(10, f'{orientation}: edge drag (→ 2–4) and move (→ 2.5–3.5) during a looping playback don\'t stop it; '
          'the loop uses the new bounds (rendered audio)',
          ok1 and ok2 and playing1 and playing2 and sel1 == (2, 4) and sel2 == (2.5, 3.5) and len(r_edge) > 2.2 * SR
          and len(r_move) > 1.5 * SR, f'{sel1} {playing1} {d1} | {sel2} {playing2} {d2}')

    # 11. Display
    s.command(f'open {os.path.abspath(SINE)}'); s.command('view 1,2'); s.command('playhead 1.5'); s.dump()
    s.snapshot('playhead')
    sb = s.state['scrollbar']
    slot = sb['knobSlot']
    lo, hi = -0.05, 4.05
    start, length = (slot['y'], slot['height']) if orientation == 'vertical' else (slot['x'], slot['width'])
    want_mark = start + (1.5 - lo) / (hi - lo) * length
    axes = {k: w['playheadAxis'] for k, w in s.state['waveforms'].items()}
    want_axis = {k: 0.5 * s.length(k) for k in axes}
    check(11, f'{orientation}: playhead line at 1.5 s in both panes (middle of view 1–2) and a mark on the scrollbar track',
          all(abs(axes[k] - want_axis[k]) < 0.5 for k in axes) and abs(sb['playheadMark'] - want_mark) < 0.5,
          f'{axes} want {want_axis}; mark {sb["playheadMark"]} want {want_mark}')
    s.command('resize 1000,700')
    s.quit()

# 12. Follow playhead
s = Session('c12', [NOISE])
s.command('view 1,2'); s.command('playhead 1.0'); s.command('follow off'); s.dump()
s.input('key space')
time.sleep(1.0)
s.dump()
v_off = s.view()
s.input('key space')
s.command('view 1,2'); s.command('playhead 1.0'); s.command('follow on'); s.dump()
s.input('key space')
time.sleep(2.5)  # follow engages when the playhead reaches the center (1.5), then 2 s
s.dump()
v_on, ph = s.view(), pb(s)['playhead']
length, center = v_on[1] - v_on[0], (v_on[0] + v_on[1]) / 2
s.snapshot('follow')
s.input(f'scroll {P(s.at("main", .5))} 0 -30')
follow_after_scroll = pb(s)['follow']
s.input('key space')
s.command('follow on'); s.dump()
s.input(f'scroll {P(s.at("main", .5))} 0 -30')
follow_stopped_scroll = pb(s)['follow']
check(12, 'follow off: the view doesn\'t move while playing', v_off == (1, 2), v_off)
check(12, f'follow on: within 2 s of reaching the center the view is ≥ 4.9 s long ({length:.2f}) with the playhead within 10% of the center '
      f'({(ph - center) / length * 100:+.1f}%)', length >= 4.9 and abs(ph - center) <= 0.1 * length, f'{v_on} {ph}')
check(12, 'a manual scroll during playback turns follow off; when stopped it doesn\'t',
      follow_after_scroll is False and follow_stopped_scroll is True, f'{follow_after_scroll} {follow_stopped_scroll}')

# 13. Remembered flags, opening a file
s.command('loop on'); s.command('follow on'); s.dump()
s.quit()
s = Session('c13', [NOISE])
remembered = (pb(s)['loop'], pb(s)['follow'])
s.command('loop off'); s.command('follow off'); s.dump()
s.quit()
s = Session('c13b', [NOISE])
remembered_off = (pb(s)['loop'], pb(s)['follow'])
s.command('playhead 3.0'); s.dump()
s.input('key space')
time.sleep(0.3)
s.command(f'open {os.path.abspath(NOISE)}'); s.dump()
p = pb(s)
s.quit()
check(13, 'loop and follow remembered across a relaunch (on, then off)', remembered == (True, True) and remembered_off == (False, False),
      f'{remembered} {remembered_off}')
check(13, 'opening a file during playback stops it, playhead 0', not p['playing'] and p['playhead'] == 0, p)

print(f'\n{sum(results)}/{len(results)} checks passed')
sys.exit(0 if all(results) else 1)
