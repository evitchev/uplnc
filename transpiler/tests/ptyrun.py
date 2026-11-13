# ptyrun.py: run a terminal program on a pseudo-terminal, feed it a script
# of events, and write everything it printed to stdout; the exit status and
# whether the termios state was restored exactly go to stderr.
#
#   ptyrun.py BIN ROWSxCOLS [ctty] [a:ARG ...]
#             [w:HEXBYTES | p | s | u:TEXT | z:ROWSxCOLS ...]
#
#     ctty    make the terminal the program's controlling terminal, so a
#             Ctrl-C written to it in cooked mode arrives as SIGINT
#     a:ARG   pass ARG to the program (before any event)
#     w:HEX   write these bytes to its terminal, then let it settle
#     p       just let it settle
#     s       mark a snapshot point in the output (see screen.py --snap)
#     u:TEXT  wait until TEXT is on the screen screen.py renders, for up to
#             60 s -- for a step that takes as long as it takes, such as a
#             build; a timeout is reported on stderr and the script goes on
#     z:RxC   resize the terminal and deliver SIGWINCH
#
# Pipe the stdout through screen.py to assert on what a user would see.
import os, pty, sys, termios, fcntl, struct, signal, time, subprocess, select
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import screen
binpath, size = sys.argv[1], sys.argv[2]
rows, cols = map(int, size.split('x'))
m, s = pty.openpty()
fcntl.ioctl(m, termios.TIOCSWINSZ, struct.pack('HHHH', rows, cols, 0, 0))
before = termios.tcgetattr(s)
args = [binpath] + [a[2:] for a in sys.argv[3:] if a.startswith('a:')]
ops = [a for a in sys.argv[3:] if not a.startswith('a:') and a != 'ctty']
def takectty():          # runs in the child, after start_new_session's setsid
    fcntl.ioctl(0, termios.TIOCSCTTY, 0)
p = subprocess.Popen(args, stdin=s, stdout=s, stderr=s, start_new_session=True,
                     preexec_fn=takectty if 'ctty' in sys.argv[3:] else None)
out = b''
SNAP = screen.SNAP       # never emitted by a program: NUL is not drawn
def drain(t=0.35):
    global out
    end = time.time()+t
    while time.time() < end:
        r,_,_ = select.select([m],[],[],0.05)
        if r:
            try: out += os.read(m, 65536)
            except OSError: break
drain()
for op in ops:
    if op.startswith('w:'):
        os.write(m, bytes.fromhex(op[2:])); drain()
    elif op == 'p':
        drain(0.3)
    elif op == 's':
        drain(0.3)
        out += SNAP
    elif op.startswith('u:'):
        end = time.time()+60
        while not any(op[2:] in l for l in screen.render(out, rows, cols)):
            if time.time() > end:
                print(f"WAIT TIMEOUT {op[2:]!r}", file=sys.stderr)
                break
            drain(0.1)
    elif op.startswith('z:'):
        rows, cols = map(int, op[2:].split('x'))
        fcntl.ioctl(m, termios.TIOCSWINSZ, struct.pack('HHHH', rows, cols, 0, 0))
        p.send_signal(signal.SIGWINCH); drain()
rc = p.wait(timeout=5)
drain(0.2)
after = termios.tcgetattr(s)
os.close(m); os.close(s)
sys.stdout.buffer.write(out)
print(f"\nRC={rc} TERMIOS_RESTORED={before==after}", file=sys.stderr)
