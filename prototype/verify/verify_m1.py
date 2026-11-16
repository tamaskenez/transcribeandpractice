"""Checks milestone 1 acceptance criteria. Run from prototype/: python3 verify/verify_m1.py"""
import json, os, subprocess, sys

OUT = 'verify/out'
AUDIO = f'{OUT}/audio'
APP = 'build/TranscribeAndPractice.app'
BIN = f'{APP}/Contents/MacOS/TranscribeAndPractice'
results = []


def check(criterion, desc, ok, detail=''):
    results.append(ok)
    print(f"{'PASS' if ok else 'FAIL'}  [{criterion}] {desc}" + (f'  -- {detail}' if detail and not ok else ''))


def run_app(name, opens=(), snapshot=False):
    dump = f'{OUT}/{name}.json'
    args = [BIN]
    for o in opens:
        args.append(f'--open={o}')
    args += [f'--dump-state={dump}', '--quit']
    if snapshot:
        args.append(f'--snapshot={OUT}/{name}.png')
    if os.path.exists(dump):
        os.remove(dump)
    subprocess.run(['perl', '-e', 'alarm 30; exec @ARGV'] + args, check=True)
    return json.load(open(dump))


# 1. Build
r = subprocess.run(['./build.sh'], capture_output=True, text=True)
check(1, 'build script exits 0 and creates the bundle', r.returncode == 0 and os.path.isfile(BIN), r.stderr[-500:])

subprocess.run([sys.executable, 'verify/gen_test_audio.py', AUDIO], check=True)
expected = json.load(open(f'{AUDIO}/expected.json'))

# 2. Empty launch
s = run_app('empty', snapshot=True)
check(2, 'one window titled "Transcribe and Practice", hint shown, nothing loaded',
      s['windowCount'] == 1 and s['windowTitle'] == 'Transcribe and Practice' and s['hintVisible']
      and s['loaded'] is None, s)

# 3. Menu
file_menu = next((m for m in s['menu'] if m['title'] == 'File'), {'items': []})
open_item = next((i for i in file_menu['items'] if i['title'] == 'Open…'), None)
check(3, 'File → Open… with ⌘O', open_item is not None and open_item.get('shortcut') == 'cmd+o', file_menu)

# 4, 5. Each valid file
for i, (name, e) in enumerate(expected['valid'].items()):
    s = run_app(f'load_{name}', [f'{AUDIO}/{name}'], snapshot=(i == 0))
    L = s['loaded']
    errs = []
    if L is None:
        errs.append(f"not loaded, alert: {s['alertText']}")
    else:
        if L['fileName'] != name: errs.append(f"fileName {L['fileName']}")
        if L['sampleRate'] != e['sampleRate']: errs.append(f"sampleRate {L['sampleRate']}")
        if L['channels'] != e['channels']: errs.append(f"channels {L['channels']}")
        if e['lossless']:
            if L['frames'] != e['frames']: errs.append(f"frames {L['frames']} != {e['frames']}")
        elif abs(L['duration'] - e['duration']) > 0.1:
            errs.append(f"duration {L['duration']:.4f} vs {e['duration']}")
        tol = 0.1 if e['lossless'] else 1.0
        for c, st in enumerate(L['channelStats']):
            for key in ('peakDBFS', 'rmsDBFS'):
                if st[key] is None or abs(st[key] - e[key][c]) > tol:
                    errs.append(f"ch{c + 1} {key} {st[key]} vs {e[key][c]:.2f}")
        labels = [r['label'] for r in L['displayedRows']]
        if labels[:5] != ['File', 'Duration', 'Sample rate', 'Channels', 'Length'] or len(labels) != 5 + e['channels']:
            errs.append(f'displayed rows {labels}')
    check(4, f'{name}: info matches expected values', not errs, '; '.join(errs))
    if L:
        bf = L['bufferFormat']
        ok = (bf['commonFormat'] == 'float32' and bf['channels'] == e['channels']
              and bf['sampleRate'] == e['sampleRate'] and bf['frames'] == L['frames'])
        check(5, f'{name}: buffer is float32, all channels, native rate', ok, bf)

# 6. Second file replaces the first
a, b = 'mono_44100_16bit.wav', 'stereo_48000_24bit.wav'
s = run_app('replace', [f'{AUDIO}/{a}', f'{AUDIO}/{b}'])
check(6, 'second file replaces the first; title shows its name',
      s['loaded'] and s['loaded']['fileName'] == b and s['windowTitle'] == b and s['windowCount'] == 1, s.get('loaded'))

# 7. Invalid files
for bad in expected['invalid']:
    s = run_app(f'invalid_{bad}', [f'{AUDIO}/{a}', f'{AUDIO}/{bad}'])
    ok = bool(s['alertText']) and s['loaded'] and s['loaded']['fileName'] == a and s['windowTitle'] == a
    check(7, f'{bad}: alert shown ({s["alertText"]!r}), previous file stays', ok, s.get('loaded'))

print(f'\n{sum(results)}/{len(results)} checks passed')
sys.exit(0 if all(results) else 1)
