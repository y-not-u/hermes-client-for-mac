#!/usr/bin/env python3
"""Deterministic Hermes dashboard protocol fixture (not a Hermes replacement)."""
import argparse
import asyncio
import json
from aiohttp import web
from mock_display import DisplayFixture

class Fixture:
    def __init__(self):
        self.sockets = set()
        self.reset()

    def reset(self):
        self.display = DisplayFixture(self)
        self.sessions = {}
        self.requests = []
        self.history_reads = []
        self.session_reads = []
        self.session_rows = []
        self.session_writes = []
        self.session_write_error = False
        self.responses = []
        self.counter = 0
        self.native = False
        self.create_delay = 0
        self.submit_delay = 0
        self.refreshes = 0
        self.tickets = 0
        self.correction_status = 'redirected'
        self.correction_delay = 0
        self.correction_error = None
        self.steer_status = 'queued'
        self.complete_on_correction = False
        self.drop_on_correction = False
        self.complete_on_resume = False
        self.resume_delay = 0
        self.model_confirm = False
        self.model_error = False
        self.model_delay = 0
        self.clarify_questions = None
        self.clarify_open = {}
        self.cancels = []

    async def control(self, request):
        body = await request.json()
        action = body.get('action')
        if action == 'reset':
            for ws in list(self.sockets):
                await ws.close()
            self.reset()
        elif action == 'configure':
            await self.display.control(body)
            self.native = body.get('native', self.native)
            self.create_delay = body.get('create_delay', self.create_delay)
            self.submit_delay = body.get('submit_delay', self.submit_delay)
            self.complete_on_resume = body.get('complete_on_resume', self.complete_on_resume)
            self.resume_delay = body.get('resume_delay', self.resume_delay)
            self.session_rows = body.get('session_rows', self.session_rows)
            self.session_write_error = body.get('session_write_error', self.session_write_error)
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
            for key in ('model_confirm', 'model_error', 'model_delay'):
                if key in body:
                    setattr(self, key, body[key])
            if 'clarify_questions' in body:
                self.clarify_questions = body['clarify_questions']
        elif action == 'clarify':
            # Deliver one server→client clarify request the way tui_gateway's server_requests.send does.
            stored = body['stored_id']
            session = self.sessions[stored]
            request_id = body.get('id', 'srq-%d' % (len(self.cancels) + len(self.clarify_open) + 1))
            self.clarify_open[request_id] = {'stored_id': stored, 'questions': body['questions']}
            frame = {'jsonrpc': '2.0', 'id': request_id, 'method': 'clarify',
                     'params': {'session_id': session['session_id'], 'questions': body['questions']}}
            if body.get('answers'):
                frame['params']['answers'] = body['answers']
            for ws in list(self.sockets):
                await ws.send_json(frame)
        elif action == 'cancel_request':
            stored = body['stored_id']
            session = self.sessions[stored]
            self.clarify_open.pop(body['id'], None)
            self.cancels.append({'id': body['id'], 'reason': body.get('reason', 'interrupted')})
            for ws in list(self.sockets):
                await ws.send_json({'jsonrpc': '2.0', 'method': 'event', 'params': {
                    'session_id': session['session_id'], 'type': 'request.cancel',
                    'payload': {'id': body['id'], 'method': 'clarify', 'reason': body.get('reason', 'interrupted')}}})
        elif action == 'drop':
            for ws in list(self.sockets):
                await ws.close()
        elif action == 'append_tools':
            self.sessions[body['stored_id']]['messages'].extend(
                {'role': 'tool', 'content': f'tool-{i}'} for i in range(body['count']))
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
        return web.json_response({'requests': self.requests, 'responses': self.responses, 'history_reads': self.history_reads, 'session_reads': self.session_reads, 'session_writes': self.session_writes,
            'refreshes': self.refreshes, 'tickets': self.tickets, 'cancels': self.cancels, 'clarify_open': list(self.clarify_open), **self.display.report()})

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
            rows = [{'id': sid, 'title': sid, 'archived': s.get('archived', False)} for sid, s in self.sessions.items() if s['profile'] == profile]
            rows.extend(r for r in self.session_rows if r['profile'] == profile)
            if profile == 'a':
                rows.append({'id': 'cli-readonly', 'title': 'CLI history'})
            excluded = request.query.get('exclude_sources', '').split(',')
            rows = [r for r in rows if r.get('source') not in excluded]
            if path.endswith('search'):
                rows = [r for r in rows if request.query.get('q', '') in r['title']]
            else:
                rows = [r for r in rows if not r.get('archived')]
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
        if path.startswith('/api/sessions/') and request.method in ('PATCH', 'DELETE'):
            sid = path.rsplit('/', 1)[-1]
            body = await request.json() if request.method == 'PATCH' else {}
            profile = body.get('profile') if request.method == 'PATCH' else request.query.get('profile')
            self.session_writes.append({'session_id': sid, 'profile': profile, 'method': request.method, 'body': body})
            if self.session_write_error:
                return web.json_response({'error': 'write refused'}, status=409)
            if sid in self.sessions and self.sessions[sid]['profile'] == profile:
                if request.method == 'DELETE':
                    del self.sessions[sid]
                else:
                    self.sessions[sid].update(body)
            if request.method == 'DELETE':
                self.session_rows = [r for r in self.session_rows if r['id'] != sid or r['profile'] != profile]
            else:
                for row in self.session_rows:
                    if row['id'] == sid and row['profile'] == profile:
                        row.update(body)
            return web.json_response({'ok': True})
        return web.json_response({'ok': True})

    async def rpc(self, ws, frame):
        method = frame.get('method')
        if not method:
            self.responses.append(frame)
            if isinstance(frame.get('id'), str) and frame['id'] in self.clarify_open:
                self.clarify_open.pop(frame['id'], None)
            return
        params = frame.get('params', {})
        self.requests.append({'method': method, 'params': params})
        result = {}
        if method.startswith('display.'):
            await self.display.rpc(ws, frame)
            return
        if method == 'model.options':
            session = next((s for s in self.sessions.values() if s['session_id'] == params.get('session_id')), {})
            result = {'provider': session.get('model_provider', 'fixture'),
                      'model': session.get('model', 'default-' + params['profile']),
                      'providers': [{'slug': 'fixture', 'name': 'Fixture', 'models': ['default-' + params['profile'], 'new-model']},
                                    {'slug': 'other', 'name': 'Other', 'models': ['new-model']}]}
        elif method == 'config.set' and params['key'] == 'model':
            await asyncio.sleep(self.model_delay)
            if self.model_error:
                await ws.send_json({'jsonrpc': '2.0', 'id': frame['id'], 'error': {'code': 5001, 'message': 'model switch refused'}})
                return
            session = next(s for s in self.sessions.values() if s['session_id'] == params['session_id'])
            words = params['value'].split()
            provider = words[words.index('--provider') + 1]
            if provider not in ('fixture', 'other'):
                await ws.send_json({'jsonrpc': '2.0', 'id': frame['id'], 'error': {'code': 5001, 'message': f"Unknown provider '{provider}'"}})
                return
            result = {'key': 'model', 'value': words[0]}
            if self.model_confirm and not params.get('confirm_expensive_model'):
                result.update(confirm_required=True, confirm_message='This model costs more.')
            else:
                session['model'] = words[0]
                session['model_provider'] = words[words.index('--provider') + 1]
        elif method == 'session.create':
            self.counter += 1
            sid = f"stored-{self.counter}"
            result = {'stored_session_id': sid, 'session_id': f"runtime-{self.counter}",
                'profile': params['profile'], 'messages': [], 'running': False}
            self.sessions[sid] = result
            await asyncio.sleep(self.create_delay)
        elif method == 'session.resume':
            await asyncio.sleep(self.resume_delay)
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
            if self.clarify_questions:
                # An unanswered clarify survives a resume as an open server request.
                self.clarify_questions, questions = None, self.clarify_questions
                request_id = 'srq-resume'
                self.clarify_open[request_id] = {'stored_id': sid, 'questions': questions}
                result.setdefault('open_requests', []).append({'id': request_id, 'method': 'clarify',
                    'params': {'session_id': result['session_id'], 'questions': questions}})
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
            if self.correction_error is not None:
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
            await asyncio.sleep(self.submit_delay)
            session = next(s for s in self.sessions.values() if s['session_id'] == params['session_id'])
            result = {'status': 'queued' if session['running'] and params.get('queued') else 'streaming'}
            session = next(s for s in self.sessions.values() if s['session_id'] == params['session_id'])
            session['running'] = True
            session['messages'].append({'role': 'user', 'content': params['text']})
        elif method == 'approval.respond':
            result = {'resolved': 0 if params.get('request_id') == 'expired' else 1}
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
    app.router.add_get('/api/display/ws', lambda request: fixture.display.websocket(request))
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
