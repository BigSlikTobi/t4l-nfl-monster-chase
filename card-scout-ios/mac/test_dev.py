from contextlib import closing, redirect_stdout
import datetime as dt
import hashlib
import io
import json
from pathlib import Path
import sqlite3
import subprocess
import tempfile
import time
import unittest
from unittest.mock import MagicMock, patch

from cardsight import Client, MONTHLY_CAP
import dev


class DeveloperCLITests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)

    def tearDown(self): self.temp.cleanup()

    def queue_fixture(self):
        path = self.root / 'queue.sqlite3'
        with closing(sqlite3.connect(path)) as db:
            db.execute('CREATE TABLE jobs(id TEXT, status TEXT, result TEXT)')
            db.executemany('INSERT INTO jobs VALUES(?,?,?)', [('private-card', 'analyzed', 'private-analysis'),
                            ('queued-card', 'queued', None), ('draft', 'identified', None)])
            db.commit()
        return path

    def test_quota_read_is_free_refresh_sanitizes_and_reuses_check(self):
        calls = []
        def transport(*args):
            calls.append(args)
            return 200, dict(calls=1200, api_keys=[dict(key='never-expose-me')])
        client = Client(self.root, transport)
        unread = dev.quota(self.root, client=client)
        self.assertEqual(unread['status'], 'unchecked')
        self.assertIsNone(unread['remaining'])
        self.assertFalse(client.ledger_path.exists())
        self.assertEqual(calls, [])
        result = dev.quota(self.root, refresh=True, client=client)
        self.assertEqual(result['remaining'], MONTHLY_CAP - 1201)
        self.assertEqual(result['used'], 1201)
        self.assertEqual(result['status'], 'ready')
        self.assertEqual(dev.quota(self.root, refresh=True, client=Client(self.root, transport)), result)
        self.assertEqual(len(calls), 1)
        self.assertNotIn('never-expose-me', json.dumps(result) + client.ledger_path.read_text())

    def test_quota_stale_blocked_failures_and_month_rollover(self):
        calls = []
        client = Client(self.root, lambda *args: (calls.append(args) or 429, {}))
        self.assertEqual(dev.quota(self.root, refresh=True, client=client)['status'], 'paused')
        self.assertIsNone(dev.quota(self.root, client=client)['remaining'])
        ledger = client.ledger(); ledger.pop('haltUntil', None); ledger['calls'] = MONTHLY_CAP
        client.ledger_path.write_text(json.dumps(ledger))
        reached = dev.quota(self.root, refresh=True, client=client)
        self.assertEqual(reached['remaining'], 0)
        self.assertEqual(reached['status'], 'limit_reached')
        self.assertEqual(len(calls), 1)
        ledger.update(calls=10, subscriptionCheckedAt=time.time()-3601)
        client.ledger_path.write_text(json.dumps(ledger))
        self.assertIsNone(dev.quota(self.root, client=client)['remaining'])
        ledger.update(month='1999-01', calls=MONTHLY_CAP)
        client.ledger_path.write_text(json.dumps(ledger))
        reset = dev.quota(self.root, client=client)
        self.assertEqual(reset['used'], 0)
        self.assertIsNone(reset['remaining']); self.assertIsNone(reset['checkedAt'])
        failing = Client(self.root, lambda *_: (503, {}))
        self.assertEqual(dev.quota(self.root, refresh=True, client=failing)['status'], 'unavailable')

    def test_queue_is_read_only_and_aggregates_without_private_card_data(self):
        path = self.queue_fixture()
        before = hashlib.sha256(path.read_bytes()).hexdigest()
        value = dev.queue(self.root)
        self.assertEqual(value, dict(total=3, counts=dict(analyzed=1, identified=1, queued=1), active=1))
        self.assertEqual(hashlib.sha256(path.read_bytes()).hexdigest(), before)
        self.assertNotIn('private-', json.dumps(value))
        missing = self.root / 'missing'; missing.mkdir()
        self.assertFalse(dev.run('queue', missing)['ok'])
        self.assertFalse((missing / 'queue.sqlite3').exists())

    def test_health_uses_authenticated_verified_https_and_sanitizes_response(self):
        (self.root / 'config.json').write_text(json.dumps(dict(host='127.0.0.1', port=8743, token='private-token')))
        response = MagicMock()
        response.__enter__.return_value = response
        response.status = 200
        response.read.return_value = b'{"status":"ok","version":"1","analysisVersion":"48","token":"never-expose-me"}'
        opener = MagicMock(); opener.open.return_value = response
        with patch('dev.ssl.create_default_context') as context, patch('dev.urllib.request.build_opener', return_value=opener) as build:
            value = dev.health(self.root)
        context.assert_called_once_with(cafile=str(self.root / 'server.crt'))
        self.assertIsInstance(build.call_args.args[0], dev.NoRedirect)
        request = opener.open.call_args.args[0]
        self.assertEqual(request.full_url, 'https://127.0.0.1:8743/v1/ping')
        self.assertEqual(request.get_header('Authorization'), 'Bearer private-token')
        self.assertEqual(value, dict(status='ok', version='1', analysisVersion='48'))
        self.assertNotIn('never-expose-me', json.dumps(value))
        self.assertIsNone(dev.NoRedirect().redirect_request(None, None, 302, 'redirect', {}, 'https://example.invalid'))
        with patch('dev.health', side_effect=ValueError('private-token')):
            self.assertNotIn('private-token', json.dumps(dev.run('health', self.root)))

    def test_json_cli_doctor_never_requests_provider_or_changes_saved_jobs(self):
        path = self.queue_fixture(); before = path.read_bytes()
        output = io.StringIO()
        with patch('dev.health', return_value=dict(status='ok')), patch.object(Client, 'request', side_effect=AssertionError('Unexpected provider call')), redirect_stdout(output):
            code = dev.main(['--data', str(self.root), '--json', 'doctor'])
        value = json.loads(output.getvalue())
        self.assertEqual(code, 0)
        self.assertTrue(value['ok'])
        self.assertIsNone(value['checks']['quota']['remaining'])
        self.assertEqual(path.read_bytes(), before)
        output = io.StringIO()
        with redirect_stdout(output): code = dev.main(['--data', str(self.root/'absent'), '--json', 'queue'])
        self.assertEqual(code, 1)
        self.assertFalse(json.loads(output.getvalue())['ok'])

    def test_ssh_preserves_user_host_trust_and_shell_quotes_paths(self):
        report = dict(command='queue', ok=True, checks={'queue': dict(ok=True,total=0,active=0,counts={})})
        with patch('dev.subprocess.run', return_value=subprocess.CompletedProcess([],0,json.dumps(report),'')) as run, redirect_stdout(io.StringIO()):
            self.assertEqual(dev.main(['--data', '/tmp/worker data;echo nope', '--ssh', 'root@example.invalid', '--json', 'queue']), 0)
        args, kwargs = run.call_args.args, run.call_args.kwargs
        command = args[0]
        self.assertIn('StrictHostKeyChecking=yes', command)
        self.assertIn("'/tmp/worker data;echo nope'", command[-1])
        self.assertTrue(command[-1].startswith('sudo -n -u cardscout python3 - '))
        self.assertNotIn('--ssh', command[-1])
        self.assertIn('sys.path.insert(0, "/opt/cardscout/service")', kwargs['input'])
        with patch('dev.subprocess.run', side_effect=subprocess.TimeoutExpired([],45,stderr='private-token')), redirect_stdout(io.StringIO()) as output:
            self.assertEqual(dev.main(['--ssh','root@example.invalid','queue']), 1)
        self.assertNotIn('private-token', output.getvalue())


if __name__ == '__main__': unittest.main()
