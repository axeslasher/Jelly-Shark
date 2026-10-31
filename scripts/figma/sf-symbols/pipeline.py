"""Turn SF Symbols templates plus SwiftUI measurements into one SVG per icon for Figma.

Each SVG is SwiftUI's layout box for the symbol at 18pt, with Apple's outline scaled to the
size SwiftUI draws and centred on the measured ink. Every <path id> is "<symbol>|<layer>|<opacity>":
opacity 1 is a drawn layer, 0 a knockout, anything between a hierarchical layer, all read off
the probe's render so default rendering modes match code. assemble.js consumes those ids.

Usage: python3 -I pipeline.py <templates dir> <metrics.tsv> <alpha dir> <svg out dir>
"""
import json
import os
import re
import statistics
import sys

K = 0.2284    # template units -> points at 18pt regular/medium; fitted against 70 SwiftUI renders
SCALE = 8     # probe render scale, pixels per point
STEP = 0.2    # opacity sampling grid, points
ERODE = 0.25  # keep samples this far inside a layer so anti-aliased edges don't count


def template_layers(path):
    """The Regular-S outline layers from an `sfsymbols export --format svg` template."""
    s = open(path).read()
    group = re.search(r'<g id="Regular-S"[^>]*>(.*?)</g>', s, re.S)
    if not group:
        raise SystemExit(f"{path}: no Regular-S group")
    return re.findall(r'<path[^>]* d="([^"]+)"', group.group(1))


def parse(d):
    """Template paths use absolute M/L/C/Z only; anything else stops the run."""
    toks = re.findall(r'[A-Za-z]|-?\d*\.?\d+(?:e-?\d+)?', d)
    out, i, cmd = [], 0, None
    while i < len(toks):
        if toks[i].isalpha():
            cmd = toks[i]
            i += 1
            if cmd not in 'MLCZ':
                raise SystemExit(f"unsupported path command {cmd!r}")
        if cmd == 'Z':
            out.append(('Z', []))
            continue
        n = 6 if cmd == 'C' else 2
        out.append((cmd, [float(t) for t in toks[i:i + n]]))
        i += n
        if cmd == 'M':
            cmd = 'L'
    return out


def flatten(segs):
    polys, poly, cur = [], [], (0, 0)
    for c, v in segs:
        if c == 'M':
            if poly:
                polys.append(poly)
            cur = (v[0], v[1])
            poly = [cur]
        elif c == 'L':
            cur = (v[0], v[1])
            poly.append(cur)
        elif c == 'C':
            p0 = cur
            for k in range(1, 17):
                u = k / 16
                a, b, cc, e = (1 - u) ** 3, 3 * u * (1 - u) ** 2, 3 * u * u * (1 - u), u ** 3
                poly.append((a * p0[0] + b * v[0] + cc * v[2] + e * v[4], a * p0[1] + b * v[1] + cc * v[3] + e * v[5]))
            cur = (v[4], v[5])
    if poly:
        polys.append(poly)
    return polys


def winding(polys, p):
    w = 0
    for poly in polys:
        for (x1, y1), (x2, y2) in zip(poly, poly[1:] + poly[:1]):
            cross = (x2 - x1) * (p[1] - y1) - (p[0] - x1) * (y2 - y1)
            if y1 <= p[1] < y2 and cross > 0:
                w += 1
            elif y2 <= p[1] < y1 and cross < 0:
                w -= 1
    return w


def build(name, d_list, metrics, alpha_dir):
    W, H, ix0, iy0, ix1, iy1 = metrics
    layers = [parse(d) for d in d_list]
    flat = [flatten(l) for l in layers]
    pts = [p for f in flat for poly in f for p in poly]
    gx0, gy0 = min(p[0] for p in pts), min(p[1] for p in pts)
    gw, gh = (max(p[0] for p in pts) - gx0) * K, (max(p[1] for p in pts) - gy0) * K
    left, top = (ix0 + ix1) / 2 - gw / 2, (iy0 + iy1) / 2 - gh / 2

    def place(x, y):
        return (x - gx0) * K + left, (y - gy0) * K + top

    placed = [[[place(*p) for p in poly] for poly in f] for f in flat]
    pw = round(W * SCALE)
    alpha = open(os.path.join(alpha_dir, name + '.a8'), 'rb').read()
    ph = len(alpha) // pw

    def well_inside(k, x, y):
        return all(winding(placed[k], (x + dx, y + dy)) != 0
                   for dx, dy in ((0, 0), (ERODE, 0), (-ERODE, 0), (0, ERODE), (0, -ERODE)))

    out = []
    for k, segs in enumerate(layers):
        xs = [p[0] for poly in placed[k] for p in poly]
        ys = [p[1] for poly in placed[k] for p in poly]
        samples, y = [], min(ys)
        while y <= max(ys):
            x = min(xs)
            while x <= max(xs):
                # Read only where this layer is topmost; a later layer would cover the pixel.
                if well_inside(k, x, y) and not any(winding(placed[j], (x, y)) != 0 for j in range(k + 1, len(layers))):
                    px, py = int(x * SCALE), int(y * SCALE)
                    if 0 <= px < pw and 0 <= py < ph:
                        samples.append(alpha[py * pw + px])
                x += STEP
            y += STEP
        if not samples:
            print(f"NOTE {name} layer {k}: nowhere topmost to sample, assumed opaque", file=sys.stderr)
        opacity = round(statistics.median(samples) / 255, 2) if samples else 1.0
        d = ''.join(c + ' '.join('%.2f %.2f' % place(v[i], v[i + 1]) for i in range(0, len(v), 2)) for c, v in segs)
        out.append((d, opacity))
    return W, H, out


def main():
    tpl_dir, metrics_path, alpha_dir, svg_dir = sys.argv[1:5]
    os.makedirs(svg_dir, exist_ok=True)
    metrics = {}
    for line in open(metrics_path):
        cols = line.rstrip('\n').split('\t')
        if cols[1] == 'ERROR':
            raise SystemExit(f"probe could not render {cols[0]}")
        metrics[cols[0]] = [float(v) for v in cols[1:]]
    for name in sorted(metrics):
        W, H, layers = build(name, template_layers(os.path.join(tpl_dir, name + '.svg')), metrics[name], alpha_dir)
        paths = ''.join(f'<path id="{name}|{i}|{op}" d="{d}" fill="#FFFFFF"/>' for i, (d, op) in enumerate(layers))
        with open(os.path.join(svg_dir, name + '.svg'), 'w') as f:
            f.write(f'<svg xmlns="http://www.w3.org/2000/svg" width="{W}" height="{H}" viewBox="0 0 {W} {H}">{paths}</svg>')
        special = [(i, op) for i, (_, op) in enumerate(layers) if op < 0.97]
        if special:
            print(f"{name}: layer opacities {special}")
    print(f"wrote {len(metrics)} SVGs to {svg_dir}")


if __name__ == '__main__':
    main()
