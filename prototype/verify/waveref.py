"""Reference waveform polyline (milestone 3 model), shared by verify_m2.py and verify_m3.py."""
import numpy as np


def reference_points(mono, sr, w, h, orientation, start, end, gain=1.0):
    """Axis position i of L+1 at time start + i·(end−start)/L; positions outside the file are omitted."""
    length, cross = (w, h) if orientation == 'horizontal' else (h, w)
    n = int(length) + 1
    i = np.arange(n)
    pos = (start + i * ((end - start) / (n - 1))) * sr
    keep = (pos >= 0) & (pos <= len(mono) - 1)
    i, pos = i[keep], pos[keep]
    i0 = pos.astype(int)
    i1 = np.minimum(i0 + 1, len(mono) - 1)
    f = pos - i0
    v = (mono[i0].astype(np.float32) * (1 - f).astype(np.float32) + mono[i1].astype(np.float32) * f.astype(np.float32)).astype(np.float64) * gain
    a = i * length / (n - 1)
    if orientation == 'horizontal':
        return np.stack([a, cross / 2 * (1 - v)], axis=1)
    return np.stack([cross / 2 * (1 + v), a], axis=1)
