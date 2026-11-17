"""Checks the milestone 4 review changes (criteria 14–20). Run from prototype/:
python3 verify/verify_m4_review.py

Plays audio (audible). Needs Accessibility and Screen Recording permission for the terminal.
Don't touch the mouse or keyboard while it runs. Screenshots: verify/out/m4/r*.png.
"""
import os, subprocess, sys, time

sys.path.insert(0, os.path.dirname(__file__))
import m4util  # noqa: E402
from m4util import (OUT, AUDIO, NOISE, SINE, Session, build_driver, noise, check, P, pb, wait_playhead,  # noqa: E402
                    Recording, segments_ok, results)

import atexit  # noqa: E402


def kill_leftovers():
    # A session left by a crashed run keeps reading its commands file and writing the same dumps.
    subprocess.run(['pkill', '-f', '^build/TranscribeAndPractice[.]app/'], capture_output=True)


kill_leftovers()
atexit.register(kill_leftovers)
subprocess.run(['./build.sh'], check=True, capture_output=True)
os.makedirs(OUT, exist_ok=True)
subprocess.run([sys.executable, 'verify/gen_test_audio_m4.py', AUDIO], check=True, capture_output=True)
m4util.X = noise()
build_driver()


def play_watch(s, seconds):
    """Dumps repeatedly for `seconds` (or until playback stops); returns the playback dicts and views."""
    out = []
    end = time.time() + seconds
    while time.time() < end:
        s.dump()
        out.append((dict(pb(s)), s.view()))
        if not pb(s)['playing']:
            break
        time.sleep(0.05)
    return out


def center_offset(s):
    v = s.view()
    return (pb(s)['playhead'] - (v[0] + v[1]) / 2) / (v[1] - v[0])


s = Session('r14', [NOISE])
s.command('loop off'); s.command('follow on')

# 14. Follow starts when the playhead reaches the center
s.command('view 1,6'); s.command('playhead 1.0'); s.dump()
s.input('key space')
wait_playhead(s, 3.0)
waiting = (s.view(), pb(s)['followEngaged'])
wait_playhead(s, 4.6, 4)
engaged = (s.view(), pb(s)['followEngaged'], center_offset(s))
s.input('key space')
check(14, 'playhead left of the center (1.0 → 3.0 in view 1–6): the view stays and follow waits',
      waiting == ((1, 6), False), waiting)
check(14, f'after the playhead passed the center: follow engaged, the view moved, playhead {engaged[2] * 100:+.1f}% '
      'from the center', engaged[1] and engaged[0][0] > 1 and abs(engaged[2]) <= 0.02, engaged)
s.command('view 5,6'); s.command('playhead 1.0'); s.dump()
s.input('key space')
time.sleep(0.5)
s.dump()
offscreen = (s.view(), pb(s)['followEngaged'])
s.input('key space')
check(14, 'playhead outside the view (1.0, view 5–6): follow engages at once and brings the view back',
      offscreen[1] and offscreen[0][0] < 5, offscreen)

# 15. No follow while the expected end is visible
s.command('view 1.5,3.5'); s.command('playhead 2.0'); s.command('select 2,3'); s.dump()
s.input('key left')
w = play_watch(s, 2)
a = all(v == (1.5, 3.5) and not p['followEngaged'] for p, v in w) and not w[-1][0]['playing']
s.command('loop on'); s.dump()
s.input('key left')
w = play_watch(s, 1.5)
s.input('key space')
b = all(v == (1.5, 3.5) and not p['followEngaged'] for p, v in w)
s.command('loop off'); s.command('view 7,10'); s.command('playhead 8.6'); s.dump()
s.input('key space')
w = play_watch(s, 2)
c = all(v == (7, 10) and not p['followEngaged'] for p, v in w) and not w[-1][0]['playing']
check(15, 'expected end in the view: selection end (2–3, view 1.5–3.5, loop off and loop on) and file end '
      '(from 8.6, view 7–10): the view never moves, follow not engaged', a and b and c, f'{a} {b} {c}')
s.command('loop on'); s.command('view 2.4,3.4'); s.command('playhead 2.5'); s.command('select 2,3'); s.dump()
s.input('key space')
w = play_watch(s, 1.2)
s.input('key space')
s.command('loop off')
d = any(p['followEngaged'] for p, v in w) and w[-1][1] != (2.4, 3.4)
check(15, 'looping, end (3.0) visible but the loop start (2.0) not: follow engages at the center', d,
      [(p['playhead'], p['followEngaged'], v) for p, v in w[::4]])
s.command('follow off')

# 16. After the stop at the selection end, play-or-stop continues from there
s.command('view 0,10'); s.command('playhead 2.0'); s.command('select 2,3'); s.dump()
s.input('key left')
play_watch(s, 2)
stopped_at = pb(s)['playhead']
rec = Recording(s, 'r16')
s.input('key space')
cont = (pb(s)['playing'], pb(s)['lastStart'])
time.sleep(0.4)
s.input('key space')
r16 = rec.stop()
ok, detail = segments_ok(r16, [(3.0, None)])
s.input('key right')
again = (pb(s)['playing'], pb(s)['lastStart'])
s.input('key left')
rewind = (pb(s)['playing'], pb(s)['lastStart'])
s.input('key space')
check(16, 'stopped at the selection end: playhead 3.0; Space plays from 3.0 (rendered audio); → plays from 3.0 again; '
      '← from the selection start 2.0',
      abs(stopped_at - 3.0) < 1e-9 and cont == (True, 3.0) and ok and len(r16) > 0.3 * m4util.SR
      and again == (True, 3.0) and rewind == (True, 2.0), f'{stopped_at} {cont} {detail} {again} {rewind}')

# 18. Set-last-playback-started (Down Arrow)
s.command('playhead 1.0'); s.dump()
s.input('key space')
wait_playhead(s, 1.6)
before = pb(s)['playhead']
s.input('key down')
p = pb(s)
set_to = (p['lastStart'], p['playing'], p['playhead'])
time.sleep(0.4)
s.input('key right')
restart = (pb(s)['playing'], pb(s)['lastStart'], pb(s)['playhead'])
s.input('key space')
check(18, f'↓ during playback sets the last start to the playhead ({set_to[0]:.3f}); → then restarts there',
      before <= set_to[0] <= set_to[2] and set_to[1] and restart[0] and restart[1] == set_to[0]
      and restart[2] - set_to[0] < 0.25, f'{before} {set_to} {restart}')
s.quit()

for orientation in ['horizontal', 'vertical']:
    s = Session(f'r_{orientation}', [NOISE], orientation)
    s.command('loop off'); s.command('follow off'); s.command('view 0,10'); s.dump()
    tol = 10 / s.length('main')
    resize = 'columnResize' if orientation == 'horizontal' else 'rowResize'
    at = lambda t: P(s.at('main', t / 10))  # noqa: E731

    # 20. A click sets the last start to the playhead; 19. dragging the playhead (stopped)
    s.input(f'click {at(3.0)}')
    clicked = (pb(s)['playhead'], pb(s)['lastStart'])
    s.input(f'move {at(3.0)}')
    cursor = s.state['waveforms']['main']['cursor']
    s.input(f'drag {at(3.0)} {at(4.0)}')
    p = pb(s)
    dragged = (p['playhead'], p['lastStart'], p['rewindPoint'], s.sel(), p['playing'])
    check(20, f'{orientation}: a click puts the playhead and the last start at the click (3.0)',
          abs(clicked[0] - 3.0) <= tol and clicked[1] == clicked[0], clicked)
    check(19, f'{orientation}: stopped, hovering the playhead shows {resize}; dragging it 3 → 4 moves the playhead, '
          'the last start and the rewind point; no selection is made',
          cursor == resize and all(abs(x - 4.0) <= tol for x in dragged[:3]) and dragged[3] is None and not dragged[4],
          f'{cursor} {dragged}')

    # 20. A new selection; 19. the selection start and the playhead drag together
    s.input(f'drag {at(2.0)} {at(3.5)}')
    p = pb(s)
    new_sel = (s.sel(), p['playhead'], p['lastStart'])
    s.input(f'drag {at(2.0)} {at(1.5)}')
    p = pb(s)
    together = (s.sel(), p['playhead'], p['lastStart'])
    check(20, f'{orientation}: a new selection (2–3.5) puts the playhead and the last start at its start',
          new_sel[0] is not None and all(abs(x - 2.0) <= tol for x in (new_sel[0][0], new_sel[1], new_sel[2])), new_sel)
    check(19, f'{orientation}: selection start, playhead and last start at 2.0: dragged together to 1.5, the end stays',
          together[0] is not None and abs(together[0][1] - new_sel[0][1]) < 1e-9
          and all(abs(x - 1.5) <= tol for x in (together[0][0], together[1], together[2])), together)

    # 17. The last start line (snapshot after moving it away from the playhead)
    s.command('view 1,3'); s.command('playhead 1.2'); s.dump()
    s.input('key space')
    wait_playhead(s, 1.6)
    s.input('key space')
    s.dump()
    ph = pb(s)['playhead']
    s.snapshot('laststart')
    axes = {k: (w['lastStartAxis'], w['playheadAxis']) for k, w in s.state['waveforms'].items()}
    sb = s.state['scrollbar']
    slot = sb['knobSlot']
    start, length = (slot['y'], slot['height']) if orientation == 'vertical' else (slot['x'], slot['width'])
    want_mark = start + (1.2 + 0.05) / 10.1 * length
    check(17, f'{orientation}: last-start line at 1.2 s and playhead line at {ph:.3f} s in both panes (view 1–3); '
          'last-start mark on the scrollbar',
          all(a is not None and b is not None and abs(a - 0.1 * s.length(k)) < 0.5
              and abs(b - (ph - 1) / 2 * s.length(k)) < 0.5 for k, (a, b) in axes.items())
          and abs(sb['lastStartMark'] - want_mark) < 0.5, f'{axes} {sb["lastStartMark"]} want {want_mark}')
    s.command('view 0,10'); s.dump()

    # 19. During playback: the last start alone; the playhead can't be grabbed
    s.input(f'click {at(1.0)}')
    s.input('key space')
    wait_playhead(s, 1.5)
    s.input(f'drag {at(1.0)} {at(0.5)}')
    p = pb(s)
    alone = (p['lastStart'], p['playing'], s.sel())
    s.input('key space')
    check(19, f'{orientation}: during playback the last-start line (1.0) drags alone to 0.5; playback goes on, no selection',
          abs(alone[0] - 0.5) <= tol and alone[1] and alone[2] is None, alone)

    s.command('loop on'); s.command('playhead 2.0'); s.command('select 2,3'); s.dump()
    s.input('key left')
    wait_playhead(s, 2.2)
    s.input(f'drag {at(2.0)} {at(1.0)}')
    p = pb(s)
    playing_edge = (s.sel(), p['lastStart'], p['playing'])
    s.input('key space')
    s.command('loop off')
    check(19, f'{orientation}: during playback the selection start and the last start (2.0) drag together to 1.0, '
          'the looping playback goes on',
          playing_edge[0] is not None and abs(playing_edge[0][0] - 1.0) <= tol and abs(playing_edge[1] - 1.0) <= tol
          and playing_edge[2], playing_edge)

    # 20. Escape
    s.command('select 2,3'); s.dump()
    s.input('key escape')
    check(20, f'{orientation}: Escape puts the playhead and the last start at the former selection start',
          (pb(s)['playhead'], pb(s)['lastStart']) == (2.0, 2.0), pb(s))
    s.command('resize 1000,700')
    s.quit()

print(f'\n{sum(results)}/{len(results)} checks passed')
sys.exit(0 if all(results) else 1)
