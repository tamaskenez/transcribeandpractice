"""Running-app session for milestone 3 verification: commands file + synthetic input driver."""
import json, os, subprocess, time

OUT = 'verify/out/m3'
BIN = 'build/TranscribeAndPractice.app/Contents/MacOS/TranscribeAndPractice'
DRIVER = f'{OUT}/inputdriver'


def build_driver():
    subprocess.run(['swiftc', '-O', 'verify/inputdriver.swift', '-o', DRIVER], check=True)


class Session:
    def __init__(self, name, opens=(), orientation='horizontal', extra=()):
        self.name = name
        self.cmd = os.path.abspath(f'{OUT}/{name}.cmd')
        for p in (self.cmd, self.cmd + '.ack'):
            if os.path.exists(p):
                os.remove(p)
        open(self.cmd, 'w').close()
        self.n = 0
        args = [BIN] + [f'--open={os.path.abspath(o)}' for o in opens]
        args += [f'--orientation={orientation}', f'--commands={self.cmd}', *extra]
        self.proc = subprocess.Popen(args, stdout=subprocess.DEVNULL)
        self.state = self.dump()
        self.bring_to_front()

    def bring_to_front(self):
        # Synthetic mouse events go to whatever window is under the pointer, so the app's window
        # must be frontmost and key.
        for _ in range(50):
            if self.state['appActive'] and self.state['windowKey']:
                return
            subprocess.run([DRIVER], input=f'front {self.proc.pid}\n', capture_output=True, text=True)
            self.command('activate')
            time.sleep(0.1)
            self.dump()
        raise RuntimeError('app window did not become key')

    def command(self, line, timeout=15):
        with open(self.cmd, 'a') as f:
            f.write(line + '\n')
        self.n += 1
        deadline = time.time() + timeout
        while time.time() < deadline:
            if os.path.exists(self.cmd + '.ack'):
                if len(open(self.cmd + '.ack').read().split('\n')) > self.n:
                    return
            time.sleep(0.02)
        raise TimeoutError(line)

    def dump(self, tag='state'):
        path = os.path.abspath(f'{OUT}/{self.name}_{tag}.json')
        self.command(f'dump {path}')
        self.state = json.load(open(path))
        return self.state

    def snapshot(self, tag):
        self.command(f'snapshot {os.path.abspath(f"{OUT}/{self.name}_{tag}.png")}')

    def input(self, *lines):
        """Posts input events; returns the driver's printed output lines. Then dumps the state."""
        r = subprocess.run([DRIVER], input='\n'.join(lines) + '\n', capture_output=True, text=True, check=True)
        time.sleep(0.15)
        self.dump()
        return r.stdout.split()

    def quit(self):
        try:
            self.command('quit')
            self.proc.wait(timeout=10)
        except Exception:
            self.proc.kill()

    # Geometry helpers: a point at fraction f of the time axis of a pane, in screen coordinates.
    def at(self, pane, f, cross=0.5):
        r = self.state['screenFrames'][pane]
        if self.state['orientation'] == 'horizontal':
            return r['x'] + f * r['width'], r['y'] + cross * r['height']
        return r['x'] + cross * r['width'], r['y'] + f * r['height']

    def length(self, pane):
        w = self.state['waveforms'][pane]['size']
        return w['width'] if self.state['orientation'] == 'horizontal' else w['height']

    def view(self):
        v = self.state['view']
        return v['start'], v['end']

    def sel(self):
        s = self.state['selection']
        return None if s is None else (s['start'], s['end'])
