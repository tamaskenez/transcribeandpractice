"""Checks milestone 2 acceptance criteria. Run from prototype/: python3 verify/verify_m2.py

Screenshots go to verify/out/m2/*.png and are inspected by hand (criteria 2, 3, 7, 8).
"""
import json, os, subprocess, sys
import numpy as np

sys.path.insert(0, os.path.dirname(__file__))
from gen_test_audio_m2 import signals  # noqa: E402
import waveref  # noqa: E402

OUT = 'verify/out/m2'
AUDIO = f'{OUT}/audio'
BIN = 'build/TranscribeAndPractice.app/Contents/MacOS/TranscribeAndPractice'
DOMAIN = 'com.tamaskenez.transcribeandpractice.prototype'
results = []


def check(criterion, desc, ok, detail=''):
    results.append(ok)
    print(f"{'PASS' if ok else 'FAIL'}  [{criterion}] {desc}" + (f'  -- {detail}' if detail and not ok else ''))


def run_app(name, opens=(), orientation=None, snapshot=False):
    dump = f'{OUT}/{name}.json'
    args = [BIN] + [f'--open={os.path.abspath(o)}' for o in opens]
    if orientation:
        args.append(f'--orientation={orientation}')
    args += [f'--dump-state={dump}', '--quit']
    if snapshot:
        args.append(f'--snapshot={OUT}/{name}.png')
    if os.path.exists(dump):
        os.remove(dump)
    subprocess.run(['perl', '-e', 'alarm 30; exec @ARGV'] + args, check=True)
    return json.load(open(dump))


def layout_ok(s, orientation):
    f, c = s['paneFrames'], s['contentSize']
    nav, div, main, tr = f['navigator'], f['divider'], f['main'], f['transport']
    problems = []
    if orientation == 'horizontal':
        if not (nav['y'] + nav['height'] <= div['y'] + 1e-6 and div['y'] + div['height'] <= main['y'] + 1e-6):
            problems.append('navigator/divider/main not stacked top to bottom')
        if not (nav['width'] == main['width'] == c['width'] and nav['x'] == main['x'] == 0):
            problems.append('panes not full width')
        ratio = nav['height'] / (nav['height'] + div['height'] + main['height'])
    else:
        if not (nav['x'] + nav['width'] <= div['x'] + 1e-6 and div['x'] + div['width'] <= main['x'] + 1e-6):
            problems.append('navigator/divider/main not left to right')
        if not (nav['height'] == main['height'] and nav['y'] == main['y']):
            problems.append('panes not equal height')
        ratio = nav['width'] / (nav['width'] + div['width'] + main['width'])
    if max(nav['y'] + nav['height'], main['y'] + main['height']) > tr['y'] + 1e-6:
        problems.append('middle section overlaps transport')
    if abs(tr['y'] + tr['height'] - c['height']) > 1e-6 or tr['width'] != c['width']:
        problems.append('transport not at the bottom, full width')
    if abs(ratio - 0.2) > 0.02:
        problems.append(f'navigator ratio {ratio:.3f}')
    tb = s['toolbar']
    if not (tb['visible'] and any(i['label'] == 'Time Orientation' for i in tb['items'])):
        problems.append('toolbar toggle missing')
    if tb['orientationSelection'] != orientation or s['orientation'] != orientation:
        problems.append('wrong orientation')
    return not problems, '; '.join(problems)


def reference_points(mono, w, h, orientation, view):
    # Milestone 3 changed the mapping and the full view (margins around the file); use the
    # shared reference with the dumped visible range.
    return waveref.reference_points(mono, 44100, w, h, orientation, view['start'], view['end'])


# 1. Builds
r = subprocess.run(['./build.sh'], capture_output=True, text=True)
check(1, 'build.sh exits 0 and creates the bundle', r.returncode == 0 and os.path.isfile(BIN), r.stderr[-500:])
cm = f'{OUT}/cmake-build'
r = subprocess.run(f'cmake -S .. -B {cm} -G Ninja >/dev/null && cmake --build {cm}', shell=True,
                   capture_output=True, text=True)
check(1, 'CMake build exits 0 and creates the bundle',
      r.returncode == 0 and os.path.isfile(f'{cm}/prototype/TranscribeAndPractice.app/Contents/MacOS/TranscribeAndPractice'),
      (r.stdout + r.stderr)[-500:])

subprocess.run([sys.executable, 'verify/gen_test_audio_m2.py', AUDIO], check=True)
subprocess.run(['defaults', 'delete', DOMAIN], capture_output=True)

# 8. Empty state (also: default orientation is horizontal)
s = run_app('empty', snapshot=True)
check(8, 'no file: panes present, no waveform points, hint shown',
      s['loaded'] is None and s['hintVisible'] and set(s['waveforms']) == {'navigator', 'main'}
      and all(len(w['points']) == 0 for w in s['waveforms'].values()), json.dumps(s['waveforms'])[:300])
check(5, 'default orientation is horizontal', s['orientation'] == 'horizontal', s['orientation'])

# 4. Menu
view = next((m for m in s['menu'] if m['title'] == 'View'), {'items': []})
items = {i['title']: i.get('shortcut') for i in view['items']}
check(4, 'View menu: Horizontal Time ⌘1, Vertical Time ⌘2',
      items.get('Horizontal Time') == 'cmd+1' and items.get('Vertical Time') == 'cmd+2', str(items))

# 2, 3, 6, 7. Layout and waveforms, both files, both orientations
sigs = signals()
for orientation in ['horizontal', 'vertical']:
    for name, data in sigs.items():
        s = run_app(f'{orientation}_{name[:-4]}', [f'{AUDIO}/{name}'], orientation, snapshot=True)
        crit = 2 if orientation == 'horizontal' else 3
        ok, detail = layout_ok(s, orientation)
        check(crit, f'{orientation} layout ({name})', ok, detail)
        mono = data.astype(np.float32).sum(axis=1, dtype=np.float32) * np.float32(1 / data.shape[1])
        for pane in ['navigator', 'main']:
            w = s['waveforms'][pane]
            ref = reference_points(mono, w['size']['width'], w['size']['height'], orientation, s['view'])
            got = np.array(w['points'])
            err = np.abs(got - ref).max() if got.shape == ref.shape else float('inf')
            check(6, f'{pane} waveform matches reference ({orientation}, {name})',
                  w['orientation'] == orientation and err <= 0.5, f'max error {err} px, shape {got.shape} vs {ref.shape}')

# 5. Persistence
run_app('persist_set_v', orientation='vertical')
s = run_app('persist_check_v')
check(5, 'vertical remembered across launches', s['orientation'] == 'vertical', s['orientation'])
run_app('persist_set_h', orientation='horizontal')
s = run_app('persist_check_h')
check(5, 'horizontal remembered across launches', s['orientation'] == 'horizontal', s['orientation'])

# 9. Transport summary, replacing files
s = run_app('two_files', [f'{AUDIO}/wave_mono.wav', f'{AUDIO}/wave_stereo.wav'])
expected_text = 'wave_stereo.wav  ·  0:04.000 (4.000 s)  ·  44.100 Hz  ·  2 (stereo)'
ok = s['transportText'] == expected_text and s['loaded']['fileName'] == 'wave_stereo.wav'
mono = sigs['wave_stereo.wav'].astype(np.float32).sum(axis=1, dtype=np.float32) * np.float32(0.5)
w = s['waveforms']['main']
ref = reference_points(mono, w['size']['width'], w['size']['height'], s['orientation'], s['view'])
ok = ok and np.abs(np.array(w['points']) - ref).max() <= 0.5
check(9, 'second file replaces waveform and transport summary', ok, s['transportText'])

# 10. Milestone 1
r = subprocess.run([sys.executable, 'verify/verify_m1.py'], capture_output=True, text=True)
fails = [l for l in r.stdout.splitlines() if l.startswith('FAIL')]
check(10, 'verify_m1.py passes', r.returncode == 0 and not fails and 'PASS' in r.stdout,
      '\n'.join(fails) or r.stdout[-300:] + r.stderr[-300:])

print(f'\n{sum(results)}/{len(results)} checks passed')
sys.exit(0 if all(results) else 1)
