#!/usr/bin/env python3
"""Controlled raw PTY echo/output workload; no user shell or configuration."""
import os
from pathlib import Path
import select
import sys
import tty

tty.setraw(sys.stdin.fileno())
control = Path(sys.argv[1])
mode = ''
tick = 0
sys.stdout.write('clock-ready\r\n')
sys.stdout.flush()
while True:
    requested = control.read_text().strip()
    if requested != mode:
        mode, tick = requested, 0
        sys.stdout.write('\r\nmode-' + mode + '-ready\r\n')
        if mode == 'history':
            sys.stdout.write(''.join(f'history-{i:04d}\r\n' for i in range(600)))
        sys.stdout.flush()
    ready, _, _ = select.select([sys.stdin], [], [], .008 if mode == 'flood' else .016)
    if ready:
        data = os.read(sys.stdin.fileno(), 4096)
        if not data:
            break
        os.write(sys.stdout.fileno(), data)
    if mode == 'flood':
        os.write(sys.stdout.fileno(), (('ASCII output 0123456789 ' * 4 + '\r\n') * 80).encode())
    elif mode == 'cold' and tick < 300:
        glyphs = ''.join(chr(0x4e00 + (tick * 60 + i) % 18000) for i in range(60))
        os.write(sys.stdout.fileno(), (glyphs + f'\r\ncold-{tick + 1}\r\n').encode())
        tick += 1
