#!/usr/bin/env python3
# Send ONE control-plane line to a running dartui workspace and print the
# reply. The stdlib-only sibling of macdart/tcl/dartui.tcl's `ui` proc (the
# Tcl client needs Tcl 8.6; macOS ships 8.5) — used by start-st-gui.sh for
# the automatic world import, and handy for scripting generally:
#
#   stgui_ctl.py ping
#   stgui_ctl.py stimport /path/to/world
#   stgui_ctl.py doit "st> (1/3) + (1/6)"
#   stgui_ctl.py --port 8181 lang classes
#
# Speaks the vm-service websocket (RFC 6455 hand-rolled, no dependencies),
# finds the isolate that registered ext.dartui.send, and calls it. Exit 0
# with the reply on stdout; exit 1 on connect/protocol failure (stderr says
# why) — the caller's retry loop keys off that.
import socket, base64, os, json, struct, sys


class WS(object):
    def __init__(self, host, port, path, timeout):
        self.s = socket.create_connection((host, port), timeout=5)
        key = base64.b64encode(os.urandom(16)).decode()
        req = ("GET %s HTTP/1.1\r\nHost: %s:%d\r\nUpgrade: websocket\r\n"
               "Connection: Upgrade\r\nSec-WebSocket-Key: %s\r\n"
               "Sec-WebSocket-Version: 13\r\n\r\n") % (path, host, port, key)
        self.s.sendall(req.encode())
        buf = b''
        while b'\r\n\r\n' not in buf:
            buf += self.s.recv(4096)
        if b'101' not in buf.split(b'\r\n')[0]:
            raise IOError('websocket handshake refused')
        self.s.settimeout(timeout)
        self.rid = 0

    def send(self, obj):
        data = json.dumps(obj).encode()
        hdr = bytearray([0x81])
        n = len(data)
        if n < 126:
            hdr.append(0x80 | n)
        elif n < 65536:
            hdr.append(0x80 | 126)
            hdr += struct.pack('>H', n)
        else:
            hdr.append(0x80 | 127)
            hdr += struct.pack('>Q', n)
        mask = os.urandom(4)
        hdr += mask
        self.s.sendall(bytes(hdr) +
                       bytes(b ^ mask[i % 4] for i, b in enumerate(data)))

    def recv_msg(self):
        def need(k):
            b = b''
            while len(b) < k:
                c = self.s.recv(k - len(b))
                if not c:
                    raise EOFError('connection closed')
                b += c
            return b
        while True:
            h = need(2)
            op = h[0] & 0x0f
            n = h[1] & 0x7f
            if n == 126:
                n = struct.unpack('>H', need(2))[0]
            elif n == 127:
                n = struct.unpack('>Q', need(8))[0]
            if h[1] & 0x80:
                need(4)
            payload = need(n) if n else b''
            if op == 1:
                return json.loads(payload.decode())

    def rpc(self, method, params):
        self.rid += 1
        rid = str(self.rid)
        self.send({'jsonrpc': '2.0', 'id': rid,
                   'method': method, 'params': params})
        while True:
            m = self.recv_msg()
            if m.get('id') == rid:
                if 'error' in m:
                    raise RuntimeError(str(m['error']))
                return m['result']


def main(argv):
    port = 8181
    timeout = 300.0
    args = argv[1:]
    while args and args[0].startswith('--'):
        if args[0] == '--port':
            port = int(args[1])
            args = args[2:]
        elif args[0].startswith('--port='):
            port = int(args[0].split('=', 1)[1])
            args = args[1:]
        elif args[0] == '--timeout':
            timeout = float(args[1])
            args = args[2:]
        else:
            sys.stderr.write('stgui_ctl.py: unknown option %s\n' % args[0])
            return 1
    if not args:
        sys.stderr.write('usage: stgui_ctl.py [--port N] <verb> [args...]\n')
        return 1
    line = ' '.join(args)
    try:
        ws = WS('127.0.0.1', port, '/ws', timeout)
        vm = ws.rpc('getVM', {})
        ui = None
        for ref in vm['isolates']:
            iso = ws.rpc('getIsolate', {'isolateId': ref['id']})
            if 'ext.dartui.send' in iso.get('extensionRPCs', []):
                ui = ref['id']
                break
        if ui is None:
            sys.stderr.write('stgui_ctl.py: no dartui UI isolate yet\n')
            return 1
        r = ws.rpc('ext.dartui.send', {'isolateId': ui, 'line': line})
        print(r.get('reply', r))
        return 0
    except Exception as e:
        sys.stderr.write('stgui_ctl.py: %s\n' % e)
        return 1


if __name__ == '__main__':
    sys.exit(main(sys.argv))
