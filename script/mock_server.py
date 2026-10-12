#!/usr/bin/env python3
"""Deterministic Hermes dashboard protocol fixture (not a Hermes replacement)."""
import argparse
import asyncio
import json
from aiohttp import web

class Fixture:
    def __init__(self):
        self.sockets = set()
        self.reset()

    def reset(self):
        self.sessions = {}
        self.requests = []
        self.history_reads = []
        self.session_reads = []
        self.session_rows = []
        self.responses = []
        self.counter = 0
        self.native = False
        self.create_delay = 0
        self.refreshes = 0
        self.tickets = 0
        self.correction_status = 'redirected'
        self.correction_delay = 0
        self.correction_error = None
        self.steer_status = 'queued'
        self.complete_on_correction = False
        self.drop_on_correction = False
        self.complete_on_resume = False

    async def control(self, request):
        body = await request.json()
        action = body.get('action')
        if action == 'reset':
            for ws in list(self.sockets):
                await ws.close()
            self.reset()
        elif action == 'configure':
            self.native = body.get('native', self.native)
            self.create_delay = body.get('create_delay', self.create_delay)
            self.complete_on_resume = body.get('complete_on_resume', self.complete_on_resume)
            self.session_rows = body.get('session_rows', self.session_rows)
            for key in ('correction_status', 'correction_delay', 'correction_error', 'steer_status', 'complete_on_correction', 'drop_on_correction'):
                if key in body:
                    setattr(self, key, body[key])
            if body.get('large_history'):
                self.sessions['large-history'] = {
                    'stored_session_id': 'large-history', 'session_id': 'runtime-large',
                    'profile': 'a', 'running': False,
                    'messages': [{'_row_id': 1, 'role': 'tool', 'content': 'x' * 2_000_000}] + [
                        {'_row_id': i + 2, 'role': 'tool' if i % 3 == 0 else ('user' if i % 3 == 1 else 'assistant'),
                         'content': f'message-{i}'} for i in range(65)]}
        elif action == 'drop':
            for ws in list(self.sockets):
                await ws.close()
        elif action == 'emit':
            stored = body['stored_id']
            session = self.sessions[stored]
            frame = body['frame']
            frame.setdefault('jsonrpc', '2.0')
            frame.setdefault('params', {})['session_id'] = session['session_id']
            if frame.get('method') == 'event' and frame['params'].get('type') == 'message.delta':
                inflight = session.setdefault('inflight', {})
                inflight['assistant'] = inflight.get('assistant', '') + frame['params'].get('payload', {}).get('text', '')
            if frame.get('method') == 'event' and frame['params'].get('type') == 'message.complete':
                session.pop('inflight', None)
                session['running'] = False
                text = frame['params'].get('payload', {}).get('text', '')
                if text:
                    session['messages'].append({'role': 'assistant', 'content': text})
            for ws in list(self.sockets):
                await ws.send_json(frame)
        return web.json_response({'requests': self.requests, 'responses': self.responses, 'history_reads': self.history_reads, 'session_reads': self.session_reads,
            'refreshes': self.refreshes, 'tickets': self.tickets})

    async def rest(self, request):
        path = request.path
        if path == '/auth/native/refresh':
            self.refreshes += 1
            return web.json_response({'access_token': 'fresh-token', 'refresh_token': 'refresh-token',
                'provider': 'fixture', 'expires_at': 9999999999})
        if request.headers.get('X-Hermes-Session-Token') != 'fixture-token' and request.headers.get('Authorization') != 'Bearer fresh-token':
            return web.json_response({'error': 'unauthorized'}, status=401)
        if path == '/api/status':
            return web.json_response({'auth_required': self.native})
        if path == '/api/auth/ws-ticket':
            self.tickets += 1
            return web.json_response({'ticket': 'fixture-ticket'})
        if path == '/api/profiles':
            return web.json_response({'profiles': [{'name': p, 'display_name': p.upper()} for p in ['a', 'b']]})
        if path in ['/api/sessions', '/api/sessions/search']:
            self.session_reads.append({'path': path, **dict(request.query)})
            profile = request.query.get('profile')
            rows = [{'id': sid, 'title': sid} for sid, s in self.sessions.items() if s['profile'] == profile]
            rows.extend(r for r in self.session_rows if r['profile'] == profile)
            if profile == 'a':
                rows.append({'id': 'cli-readonly', 'title': 'CLI history'})
            excluded = request.query.get('exclude_sources', '').split(',')
            rows = [r for r in rows if r.get('source') not in excluded]
            if path.endswith('search'):
                rows = [r for r in rows if request.query.get('q', '') in r['title']]
            offset = int(request.query.get('offset', 0))
            limit = int(request.query.get('limit', 40))
            rows = rows[offset:offset + limit]
            return web.json_response({'results' if path.endswith('search') else 'sessions': rows})
        if path.endswith('/messages'):
            sid = request.match_info['sid']
            self.history_reads.append({'session_id': sid, **dict(request.query)})
            messages = [{'role': 'user', 'content': 'CLI question'}, {'role': 'assistant', 'content': 'CLI answer'}] if sid == 'cli-readonly' else self.sessions[sid]['messages']
            limit = int(request.query.get('limit', 20))
            offset = int(request.query.get('offset', 0))
            if request.query.get('order') == 'latest':
                end = max(0, len(messages) - offset)
                messages = messages[max(0, end - limit):end]
            else:
                messages = messages[offset:offset + limit]
            return web.json_response({'messages': messages})
        return web.json_response({'ok': True})

    async def rpc(self, ws, frame):
        method = frame.get('method')
        if not method:
            self.responses.append(frame)
            return
        params = frame.get('params', {})
        self.requests.append({'method': method, 'params': params})
        result = {}
        if method == 'session.create':
            self.counter += 1
            sid = f"stored-{self.counter}"
            result = {'stored_session_id': sid, 'session_id': f"runtime-{self.counter}",
                'profile': params['profile'], 'messages': [], 'running': False}
            self.sessions[sid] = result
            await asyncio.sleep(self.create_delay)
        elif method == 'session.resume':
            sid = params['session_id']
            if sid == 'cli-readonly':
                await ws.send_json({'jsonrpc': '2.0', 'id': frame['id'], 'error': {'code': -32000, 'message': 'history cannot be resumed'}})
                return
            if self.complete_on_resume:
                self.complete_on_resume = False
                session = self.sessions[sid]
                session['running'] = False
                session.pop('inflight', None)
                session['messages'].append({'role': 'assistant', 'content': 'finished during resume'})
                await ws.send_json({'jsonrpc': '2.0', 'method': 'event', 'params': {
                    'session_id': session['session_id'], 'type': 'message.complete',
                    'payload': {'text': 'finished during resume'}}})
            result = dict(self.sessions[sid])
            if params.get('omit_messages'):
                result['message_count'] = len(result['messages'])
                result['messages'] = []
                result['messages_omitted'] = True
        elif method in ('session.redirect', 'session.steer'):
            session = next(s for s in self.sessions.values() if s['session_id'] == params['session_id'])
            await asyncio.sleep(self.correction_delay)
            if self.drop_on_correction:
                await ws.close()
                return
            if self.correction_error is not None and method == 'session.redirect':
                await ws.send_json({'jsonrpc': '2.0', 'id': frame['id'], 'error': {'code': self.correction_error, 'message': 'correction refused'}})
                return
            if self.complete_on_correction:
                self.complete_on_correction = False
                session['running'] = False
                await ws.send_json({'jsonrpc': '2.0', 'method': 'event', 'params': {
                    'session_id': session['session_id'], 'type': 'message.complete', 'payload': {'text': 'original finished'}}})
            status = (self.correction_status if method == 'session.redirect' else self.steer_status) if session['running'] else 'rejected'
            result = {'status': status, 'text': params['text']}
            if status != 'rejected':
                session.setdefault('inflight', {}).setdefault('corrections', []).append(params['text'])
        elif method == 'prompt.submit':
            session = next(s for s in self.sessions.values() if s['session_id'] == params['session_id'])
            result = {'status': 'queued' if session['running'] and params.get('queued') else 'streaming'}
            session = next(s for s in self.sessions.values() if s['session_id'] == params['session_id'])
            session['running'] = True
            session['messages'].append({'role': 'user', 'content': params['text']})
        elif method == 'session.interrupt':
            session = next(s for s in self.sessions.values() if s['session_id'] == params['session_id'])
            session['running'] = False
            await ws.send_json({'jsonrpc': '2.0', 'method': 'event', 'params': {'session_id': session['session_id'], 'type': 'message.complete', 'payload': {'text': 'interrupted'}}})
        await ws.send_json({'jsonrpc': '2.0', 'id': frame['id'], 'result': result})

    async def websocket(self, request):
        if request.query.get('token') != 'fixture-token' and request.query.get('ticket') != 'fixture-ticket':
            return web.Response(status=401)
        ws = web.WebSocketResponse()
        await ws.prepare(request)
        self.sockets.add(ws)
        tasks = set()
        try:
            async for message in ws:
                if message.type == web.WSMsgType.TEXT:
                    task = asyncio.create_task(self.rpc(ws, json.loads(message.data)))
                    tasks.add(task)
                    task.add_done_callback(tasks.discard)
        finally:
            self.sockets.discard(ws)
            for task in tasks:
                task.cancel()
        return ws

async def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--port', type=int, default=19119)
    parser.add_argument('--ready-file')
    args = parser.parse_args()
    fixture = Fixture()
    app = web.Application()
    app.router.add_post('/__test', fixture.control)
    app.router.add_get('/api/ws', fixture.websocket)
    app.router.add_route('*', '/api/sessions/{sid}/messages', fixture.rest)
    app.router.add_route('*', '/{tail:.*}', fixture.rest)
    runner = web.AppRunner(app)
    await runner.setup()
    site = web.TCPSite(runner, '127.0.0.1', args.port)
    await site.start()
    port = site._server.sockets[0].getsockname()[1]
    if args.ready_file:
        with open(args.ready_file, 'w') as handle:
            handle.write(f'http://127.0.0.1:{port}')
    print(f'Fixture listening on http://127.0.0.1:{port}', flush=True)
    await asyncio.Event().wait()

if __name__ == '__main__':
    asyncio.run(main())
