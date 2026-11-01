import importlib.util
import json
import os
from pathlib import Path
import plistlib
import shutil
import socket
import struct
import subprocess
import sys
import tempfile
import threading
import unittest
from unittest.mock import patch

SCRIPTS = Path(__file__).resolve().parents[2] / 'scripts'
sys.path.insert(0, str(SCRIPTS))
spec = importlib.util.spec_from_file_location('mac_build', SCRIPTS / 'mac_build.py')
mac = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mac)


class MacBuildTests(unittest.TestCase):
    def test_certificate_pin_rejects_same_team_other_key_and_ambiguous_first_install(self):
        one, two = 'A' * 40, 'B' * 40
        available = [(one, 'Apple Development: First (KEYIDENT01)', 'ABCDEFGHIJ'), (two, 'Apple Development: Second (KEYIDENT02)', 'ABCDEFGHIJ')]
        self.assertEqual(mac.choose_certificate(available, 'ABCDEFGHIJ', one), one)
        with self.assertRaises(ValueError): mac.choose_certificate(available, 'ABCDEFGHIJ')
        with self.assertRaises(ValueError): mac.choose_certificate(available, 'ABCDEFGHIJ', one, two)
        with self.assertRaises(ValueError): mac.choose_certificate(available[1:], 'ABCDEFGHIJ', one)
        with self.assertRaises(ValueError): mac.choose_certificate(available, 'OTHERTEAM1', one)

    def test_checkout_builds_committed_revision_preserves_index_and_working_edits(self):
        with tempfile.TemporaryDirectory() as temporary:
            source, target = Path(temporary) / 'repo', Path(temporary) / 'detached'
            source.mkdir(); (source / 'Config').mkdir()
            def git(*args): return subprocess.check_output(['git', '-C', str(source), *args])
            git('init', '-q', '-b', 'main')
            (source / 'source').write_text('committed')
            git('add', 'source'); git('-c', 'user.name=Fixture', '-c', 'user.email=fixture@example.invalid', 'commit', '-qm', 'fixture')
            (source / 'source').write_text('staged'); git('add', 'source')
            (source / 'source').write_text('working')
            (source / 'Config/Local.xcconfig').write_text('private fixture')
            before = git('diff', '--cached')
            mac.checkout(source, git('rev-parse', 'HEAD').decode().strip(), target)
            self.assertEqual((target / 'source').read_text(), 'committed')
            self.assertEqual((source / 'source').read_text(), 'working')
            self.assertEqual(before, git('diff', '--cached'))
            self.assertEqual(subprocess.check_output(['git','-C',str(target),'rev-parse','--abbrev-ref','HEAD']).strip(), b'HEAD')
            self.assertEqual((target / 'Config/Local.xcconfig').read_text(), 'private fixture')
            git('worktree', 'remove', '--force', str(target))

    def test_local_rpc_drains_fragmented_production_framing(self):
        with tempfile.TemporaryDirectory(prefix='orbit-rpc-', dir='/tmp') as temporary:
            listener = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            listener.bind(str(Path(temporary) / 'control.sock')); listener.listen()
            received = []
            def serve():
                stream, _ = listener.accept()
                with stream:
                    data = stream.recv(8)
                    received.append(data[:4]); length = struct.unpack('>I', data[4:])[0]
                    payload = bytearray()
                    while len(payload) < length: payload.extend(stream.recv(length-len(payload)))
                    received.append(json.loads(payload))
                    reply = json.dumps({'result': {'runningRevision': 'test'}}).encode()
                    for byte in struct.pack('>I', len(reply)) + reply: stream.sendall(bytes([byte]))
            thread = threading.Thread(target=serve); thread.start()
            try: self.assertEqual(mac.local_rpc(temporary, 'mac_update_status')['result']['runningRevision'], 'test')
            finally: thread.join(5); listener.close()
            self.assertEqual(received[0], b'ORBT')
            self.assertEqual(received[1]['method'], 'mac_update_status')

    def test_identity_rejected_before_stopping_existing_copy(self):
        installation = dict(path='/unused', bundleID='test.orbit.mac', certificate='A'*40, requirement='existing')
        with patch.object(mac, 'run'), patch.object(mac, 'info', return_value={'CFBundleIdentifier':'wrong.bundle.id'}), patch.object(mac, 'stop_apps') as stop:
            with self.assertRaises(ValueError): mac.install(Path('/staged'), installation)
            stop.assert_not_called()

    def test_install_exact_replacement_and_rollback(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary); staged, installed = root/'Staged.app', root/'Orbit Mac.app'
            for app in [staged, installed]:
                (app/'Contents').mkdir(parents=True)
                (app/'Contents/Info.plist').write_bytes(plistlib.dumps({'CFBundleIdentifier':'test.orbit.mac'}))
            (installed/'obsolete').write_text('old'); (staged/'new').write_text('new')
            installation = dict(path=str(installed), bundleID='test.orbit.mac', certificate='A'*40, requirement='existing')
            def command(args, **kwargs):
                if args[0] == '/usr/bin/ditto': shutil.copytree(args[1], args[2])
                return ''
            with patch.object(mac,'REGISTRY',root/'registry.json'), patch.object(mac,'run',side_effect=command), patch.object(mac,'certificate',return_value='A'*40), patch.object(mac,'stop_apps'):
                mac.install(staged, installation)
                self.assertFalse((installed/'obsolete').exists())
                self.assertTrue((installed/'new').exists())
                self.assertEqual(json.loads((root/'registry.json').read_text())['certificate'], 'A'*40)
                def failure(args, **kwargs):
                    command(args, **kwargs)
                    if args[0] == '/usr/bin/codesign' and args[-1] == installed and (installed/'break').exists(): raise ValueError('synthetic post-move failure')
                    return ''
                (staged/'break').write_text('bad')
                with patch.object(mac,'run',side_effect=failure), patch.object(mac.subprocess,'run'):
                    with self.assertRaises(ValueError): mac.install(staged, installation)
                self.assertFalse((installed/'break').exists())
                self.assertTrue((installed/'new').exists())

    def test_repeated_builds_use_fresh_detached_source_at_stable_paths(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary); source = root/'repo'; source.mkdir()
            def git(*args): return subprocess.check_output(['git','-C',str(source),*args])
            git('init','-q','-b','main')
            (source/'scripts').mkdir(); (source/'Config').mkdir()
            (source/'Config/Local.xcconfig').write_text('private')
            (source/'.gitignore').write_text('Config/Local.xcconfig\ndist/\n')
            (source/'scripts/package_mac_app.sh').write_text("#!/bin/bash\nset -eu\nmkdir -p \"$ORBIT_MAC_BUILD_CACHE/artifacts/fixture\" 'dist/Orbit Mac.app'\nprintf '%s' \"$PWD\" > 'dist/Orbit Mac.app/source-path'\n")
            git('add','.'); git('-c','user.name=Fixture','-c','user.email=fixture@example.invalid','commit','-qm','fixture')
            registry = root/'state/mac-installation.json'; registry.parent.mkdir()
            original_run = mac.run
            def command(args, **kwargs):
                if str(args[0]) == '/usr/bin/ditto':
                    shutil.copytree(args[1],args[2]); return ''
                return original_run(args, **kwargs)
            with patch.object(mac,'REGISTRY',registry), patch.object(mac,'select_xcode',return_value='/fixture/Xcode'), patch.object(mac,'run',side_effect=command):
                mac.build(source,'--build-only')
                first = (source/'dist/Orbit Mac.app/source-path').read_text()
                self.assertFalse((registry.parent/'MacBuildSource').exists())
                mac.build(source,'--build-only')
                self.assertEqual((source/'dist/Orbit Mac.app/source-path').read_text(), first)
                self.assertFalse((registry.parent/'MacBuildSource').exists())
                self.assertEqual(git('status','--porcelain'), b'')
                git('worktree','add','-b','protected',str(registry.parent/'MacBuildSource'))
                with self.assertRaises(ValueError): mac.build(source,'--build-only')
                self.assertTrue((registry.parent/'MacBuildSource/scripts/package_mac_app.sh').exists())
                git('worktree','remove','--force',str(registry.parent/'MacBuildSource'))

    def test_durable_job_and_exclusive_lock(self):
        with tempfile.TemporaryDirectory() as temporary, patch.object(mac, 'REGISTRY', Path(temporary)/'registry.json'):
            fd = mac.lock()
            try:
                with self.assertRaises(ValueError): mac.lock()
                job = Path(temporary)/'MacUpdate/job.json'
                mac.update_job(job, id='test', state='building')
                mac.update_job(job, state='failed', failure='synthetic')
                self.assertEqual(mac.read(job)['id'], 'test')
                self.assertEqual(mac.read(job)['state'], 'failed')
                self.assertEqual(job.stat().st_mode & 0o777, 0o600)
            finally: os.close(fd)
