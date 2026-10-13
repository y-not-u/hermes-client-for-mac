"""Strict Bot Screen fixture based on Hermes 8f817911 (not a real Xfce server).

Uses connection-scoped minted viewer identities, one-shot tickets and RFB 3.8.
The framebuffer is deliberately a synthetic test pattern; input is recorded only
when its viewer holds the lease, matching the gateway's server-side fence.
"""
import asyncio
import hashlib
import secrets
import struct
import time
from aiohttp import web


class DisplayFixture:
    def __init__(self, owner):
        self.owner = owner
        self.reset()

    def reset(self):
        self.states = {}
        self.minted = {}
        self.tickets = {}
        self.sockets = set()
        self.inputs = []
        self.handshakes = 0
        self.frames = 0
        self.unknown_method = False
        self.installed = True
        self.supported = True
        self.delay = 0
        self.delay_method = ''
        self.error_method = ''
        self.drop_after_mutation = False
        self.observe_path = '/api/display/ws'

    def state(self, profile):
        return self.states.setdefault(profile, {'running': False, 'holder': 'agent', 'viewer_id': '', 'epoch': 0})

    def lease(self, profile):
        st = self.state(profile)
        return {'holder': st['holder'], 'viewer_id': None,
                'viewer_hash': hashlib.sha256(st['viewer_id'].encode()).hexdigest()[:12] if st['viewer_id'] else None,
                'since': time.time(), 'reason': '', 'epoch': st['epoch']}

    def snapshot(self, profile):
        return {'profile': '/fixture/home/' + profile, 'profile_key': 'home-key-' + profile,
                'supported': self.supported, 'installed': self.installed,
                'missing': [] if self.installed else ['Xvnc', 'xfwm4'],
                'running': self.state(profile)['running'], 'geometry': '640x400',
                'pid': 42 if self.state(profile)['running'] else None,
                'display': ':99', 'socket': '/fixture/rfb.sock', 'placement': 'gateway',
                'browser': '/usr/bin/chromium', 'blocker': None,
                'install_command': None if self.installed else 'sudo apt-get install tigervnc-standalone-server xfwm4',
                'lease': self.lease(profile)}

    async def broadcast(self, profile):
        frame = {'jsonrpc': '2.0', 'method': 'event', 'params': {'type': 'display.lease',
                 'payload': {'profile_key': 'home-key-' + profile, 'lease': self.lease(profile)}}}
        for ws in list(self.owner.sockets):
            if not ws.closed:
                await ws.send_json(frame)

    async def rpc(self, ws, frame):
        method, params = frame['method'], frame.get('params', {})
        profile = params.get('profile')
        allowed = {
            'display.status': {'profile'}, 'display.start': {'profile'}, 'display.stop': {'profile', 'force'},
            'display.observe': {'profile', 'viewer_id'},
            'display.lease.acquire': {'profile', 'viewer_id', 'reason'},
            'display.lease.release': {'profile', 'viewer_id', 'force'},
        }
        async def error(code, message):
            await ws.send_json({'jsonrpc': '2.0', 'id': frame['id'], 'error': {'code': code, 'message': message}})
        if self.unknown_method or method not in allowed:
            await error(-32601, 'Method not found')
            return
        if not profile or set(params) - allowed[method]:
            await error(-32602, 'Invalid display parameters')
            return
        if self.error_method == method:
            await error(5300, 'Fixture display operation refused')
            return
        st = self.state(profile)
        mine = self.minted.setdefault(ws, set())
        if method == 'display.start':
            if not self.installed or not self.supported:
                await error(5300, 'Screen packages missing or unsupported host')
                return
            st['running'] = True
        elif method == 'display.stop':
            if st['holder'] == 'human' and not params.get('force'):
                await error(5300, 'a human holds this screen')
                return
            st['running'] = False
        elif method == 'display.observe':
            if not st['running']:
                await error(5300, 'Bot Desktop is not running')
                return
            viewer = params.get('viewer_id')
            if viewer not in mine:
                viewer = secrets.token_urlsafe(16)
                mine.add(viewer)
            ticket = secrets.token_urlsafe(24)
            self.tickets[ticket] = (profile, viewer, time.monotonic() + 30)
            result = {**self.snapshot(profile), 'viewer_id': viewer, 'ticket': ticket, 'path': self.observe_path}
        elif method.startswith('display.lease.'):
            viewer = params.get('viewer_id')
            if viewer not in mine and not params.get('force'):
                await error(5300, 'viewer_id was not minted for this connection')
                return
            if method.endswith('acquire'):
                st.update(holder='human', viewer_id=viewer, epoch=st['epoch'] + 1)
            elif st['viewer_id'] == viewer or params.get('force'):
                st.update(holder='agent', viewer_id='', epoch=st['epoch'] + 1)
            result = {'lease': self.lease(profile)}
            await self.broadcast(profile)
            if self.drop_after_mutation:
                await ws.close()
                return
        if method not in ('display.observe', 'display.lease.acquire', 'display.lease.release'):
            result = self.snapshot(profile)
        # Capture before delay so the fixture can reproduce a late response to a stale read.
        if method == self.delay_method:
            await asyncio.sleep(self.delay)
        if not ws.closed:
            await ws.send_json({'jsonrpc': '2.0', 'id': frame['id'], 'result': result})

    async def control(self, body):
        for key in ('unknown_method', 'installed', 'supported', 'delay', 'delay_method', 'error_method',
                    'drop_after_mutation', 'observe_path'):
            if 'display_' + key in body:
                setattr(self, key, body['display_' + key])
        if body.get('display_running') is not None:
            self.state(body.get('profile', 'a'))['running'] = body['display_running']
        if body.get('display_other_viewer'):
            profile = body.get('profile', 'a')
            st = self.state(profile)
            st.update(holder='human', viewer_id='another-human', epoch=st['epoch'] + 1)
            await self.broadcast(profile)
        if body.get('display_drop_stream'):
            for ws in list(self.sockets):
                await ws.close()

    def report(self):
        return {'display_states': {p: self.snapshot(p) for p in self.states}, 'display_inputs': self.inputs,
                'display_handshakes': self.handshakes, 'display_frames': self.frames,
                'display_connections': len(self.sockets)}

    async def websocket(self, request):
        ticket = self.tickets.pop(request.query.get('display_ticket', ''), None)
        if not ticket or ticket[2] < time.monotonic():
            return web.Response(status=401)
        profile, viewer, _ = ticket
        ws = web.WebSocketResponse(protocols=('binary',), max_msg_size=2**20)
        await ws.prepare(request)
        self.sockets.add(ws)
        buffer = bytearray()
        async def read(count):
            while len(buffer) < count:
                message = await ws.receive()
                if message.type != web.WSMsgType.BINARY:
                    raise EOFError()
                buffer.extend(message.data)
            data = bytes(buffer[:count])
            del buffer[:count]
            return data
        try:
            await ws.send_bytes(b'RFB 003.008\n')
            if await read(12) != b'RFB 003.008\n':
                raise EOFError()
            await ws.send_bytes(b'\x01\x01')  # One security type: None (authenticated by ticket).
            if await read(1) != b'\x01':
                raise EOFError()
            await ws.send_bytes(b'\0' * 4)
            await read(1)  # ClientInit shared flag
            width, height = 640, 400
            pixel_format = struct.pack('>BBBBHHHBBBxxx', 32, 24, 0, 1, 255, 255, 255, 16, 8, 0)
            name = b'HermesMac RFB test pattern (simulated)'
            await ws.send_bytes(struct.pack('>HH', width, height) + pixel_format + struct.pack('>I', len(name)) + name)
            self.handshakes += 1
            sent_frame = False
            wire_format = (32, 24, 0, 1, 255, 255, 255, 16, 8, 0)
            while not ws.closed:
                kind = (await read(1))[0]
                if kind == 0:  # SetPixelFormat
                    data = await read(19)
                    wire_format = struct.unpack('>BBBBHHHBBBxxx', data[3:])
                elif kind == 2:  # SetEncodings
                    header = await read(3)
                    await read(4 * struct.unpack('>H', header[1:])[0])
                elif kind == 3:  # FramebufferUpdateRequest
                    header = await read(9)
                    if not sent_frame or header[0] == 0:
                        bpp, _, big_endian, _, red_max, green_max, blue_max, red_shift, green_shift, blue_shift = wire_format
                        pixels = b''.join(((65 * red_max // 255 << red_shift)
                                          | ((40 + (y // 50) * 20) * green_max // 255 << green_shift)
                                          | ((48 + (x // 80) * 20) * blue_max // 255 << blue_shift))
                                         .to_bytes(bpp // 8, 'big' if big_endian else 'little')
                                         for y in range(height) for x in range(width))
                        await ws.send_bytes(b'\0\0\0\x01' + struct.pack('>HHHHi', 0, 0, width, height, 0) + pixels)
                        self.frames += 1
                        sent_frame = True
                elif kind in (4, 5):
                    data = await read(7 if kind == 4 else 5)
                    if self.state(profile)['viewer_id'] == viewer and self.state(profile)['holder'] == 'human':
                        self.inputs.append({'profile': profile, 'kind': kind, 'hex': data.hex()})
                elif kind == 6:  # ClientCutText
                    header = await read(7)
                    await read(struct.unpack('>I', header[3:])[0])
                else:
                    raise EOFError()
        except (EOFError, ConnectionError, asyncio.CancelledError):
            pass
        finally:
            self.sockets.discard(ws)
            await ws.close()
        return ws
