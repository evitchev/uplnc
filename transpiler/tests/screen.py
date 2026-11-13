# Replay a terminal byte stream into a screen model and print the final grid.
# Understands what ide/tui.e emits: CSI row;colH, CSI 2J, SGR (ignored for
# content), the DEC charset shifts, and printable bytes; and the CR, LF (with
# scrolling), BS and TAB of a program's plain output.
#
#   screen.py ROWSxCOLS [--snap N] [--alt]
#
# --snap N replays only up to ptyrun.py's Nth snapshot mark (1-based), to see
# a screen in the middle of a session; otherwise the marks are ignored.
# --alt keeps the primary and alternate screens apart, as a terminal does
# (CSI ?1049 h/l), and shows the one in use: the IDE draws on the alternate
# screen, and a program it runs -- its user screen -- on the primary one.
# Without it there is one grid, so the IDE's last frame survives its exit.
# ptyrun.py imports render() to wait for text to appear on the screen.
import sys, re

SNAP = b'\x00SNAP\x00'

def render(data, rows, cols, alt=False):
    """The screen after replaying data, one right-stripped string per row."""
    g = [[' ']*cols for _ in range(rows)]
    cy = cx = 0
    primary = None      # with alt: the primary grid and cursor, while hidden
    data = data.replace(SNAP, b'')
    i = 0
    while i < len(data):
        c = data[i]
        if c == 0x1b:
            m = re.match(rb'\x1b\[([0-9;]*)([A-Za-z])', data[i:])
            if m:
                args, fin = m.group(1), m.group(2)
                if fin == b'H':
                    p = [int(x) for x in args.split(b';') if x != b'']
                    cy = (p[0]-1) if len(p) > 0 else 0
                    cx = (p[1]-1) if len(p) > 1 else 0
                elif fin == b'J':
                    g = [[' ']*cols for _ in range(rows)]
                i += m.end()
                continue
            m = re.match(rb'\x1b[()][0B]', data[i:])
            if m:
                i += m.end()
                continue
            m = re.match(rb'\x1b\[\?([0-9]+)([hl])', data[i:])
            if m:
                if alt and m.group(1) == b'1049':
                    if m.group(2) == b'h' and primary is None:
                        primary = (g, cy, cx)
                        g = [[' ']*cols for _ in range(rows)]
                    elif m.group(2) == b'l' and primary is not None:
                        g, cy, cx = primary
                        primary = None
                i += m.end()
                continue
            i += 1
            continue
        if 32 <= c < 127:
            if 0 <= cy < rows and 0 <= cx < cols:
                g[cy][cx] = chr(c)
            cx += 1
        elif c == 13:
            cx = 0
        elif c == 10:
            if cy == rows-1:
                g = g[1:] + [[' ']*cols]
            else:
                cy += 1
        elif c == 8:
            cx = max(cx-1, 0)
        elif c == 9:
            cx = min((cx//8+1)*8, cols-1)
        i += 1
    return [''.join(r).rstrip() for r in g]

if __name__ == '__main__':
    rows, cols = (int(x) for x in sys.argv[1].split('x'))
    data = sys.stdin.buffer.read()
    if '--snap' in sys.argv:
        n = int(sys.argv[sys.argv.index('--snap')+1])
        data = SNAP.join(data.split(SNAP)[:n])
    for line in render(data, rows, cols, '--alt' in sys.argv):
        print(line)
