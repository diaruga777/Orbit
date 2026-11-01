import importlib.util
import json
import os
from pathlib import Path
import plistlib
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location('mac_target', ROOT / 'Sources/OrbitHost/Resources/MacTargets/mac_target.py')
mac = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(mac)


class MacTargetsTests(unittest.TestCase):
    def test_certificate_selection_never_falls_back_from_pin(self):
        with patch.object(mac, 'available_certificates', return_value=[('A' * 40, 'Apple Development: Test'), ('B' * 40, 'Apple Development: Other')]):
            self.assertEqual(mac.select_certificate(pinned='A' * 40), 'A' * 40)
            for requested, pinned in [(None, None), (None, 'C' * 40), ('Apple Development: Other', 'A' * 40)]:
                with self.assertRaises(ValueError):
                    mac.select_certificate(requested, pinned)

    def test_mac_catalog_worker_is_bundled(self):
        self.assertIn('.copy("Resources/MacTargets")', (ROOT / 'Package.swift').read_text())

    def test_unknown_platform_and_bundle_names(self):
        for value in ('', 'a/b', '..', '\x00'):
            with self.assertRaises(ValueError):
                mac.safe_name(value)
        for value in ('', 'demo', 'a.b', 'a.b.c/evil'):
            with self.assertRaises(ValueError):
                mac.bundle_id(value)

    def fixture(self, folder):
        app = Path(folder) / 'Installed.app'
        staged = Path(folder) / 'Staged.app'
        for path, binary in [(app, b'previous'), (staged, b'new')]:
            (path / 'Contents/MacOS').mkdir(parents=True)
            (path / 'Contents/Info.plist').write_bytes(plistlib.dumps(dict(CFBundleIdentifier='test.fixture.mac', CFBundleExecutable='Fixture')))
            (path / 'Contents/MacOS/Fixture').write_bytes(binary)
        job = Path(folder) / 'job.json'
        mac.write(job, dict(id='123', state='running', phase='building', launch=True))
        config = dict(installPath=str(app), bundleID='test.fixture.mac', certificate='A' * 40, requirement='original requirement')
        mac.write(Path(folder) / 'config.json', config)
        return app, staged, job, config

    def copier(self, args, cwd=None):
        if args[0] == '/usr/bin/ditto':
            import shutil
            shutil.copytree(args[1], args[2])
        return ''

    def test_identity_mismatch_leaves_running_app_intact(self):
        with tempfile.TemporaryDirectory() as folder:
            app, staged, job, config = self.fixture(folder)
            with patch.object(mac, 'signature', return_value=('B' * 40, 'new')), patch.object(mac, 'stop') as stop:
                with self.assertRaisesRegex(ValueError, 'certificate changed'):
                    mac.install(staged, config, job, True)
                stop.assert_not_called()
            self.assertEqual((app / 'Contents/MacOS/Fixture').read_bytes(), b'previous')

    def test_original_requirement_is_checked_on_replacement(self):
        with tempfile.TemporaryDirectory() as folder:
            app, _, _, config = self.fixture(folder)
            with patch.object(mac, 'signature', return_value=('A' * 40, 'req')), patch.object(mac, 'run') as run:
                mac.verify(app, config)
                self.assertIn('=original requirement', run.call_args.args[0])

    def test_install_reads_back_binary_before_success(self):
        with tempfile.TemporaryDirectory() as folder:
            app, staged, job, config = self.fixture(folder)
            with patch.object(mac, 'verify'), patch.object(mac, 'run', side_effect=self.copier), patch.object(mac, 'stop'):
                mac.install(staged, config, job, False)
            value = mac.read(job)
            self.assertEqual(value['state'], 'succeeded')
            self.assertFalse(value['launched'])
            self.assertEqual(value['executableDigest'], mac.digest(app))
            self.assertFalse((Path(folder) / '.orbit-install-123').exists())

    def test_launch_failure_rolls_back_previous_bundle(self):
        with tempfile.TemporaryDirectory() as folder:
            app, staged, job, config = self.fixture(folder)
            def command(args, cwd=None):
                if args[0] == '/usr/bin/open':
                    raise ValueError('Launch failed')
                return self.copier(args, cwd)
            with patch.object(mac, 'verify'), patch.object(mac, 'run', side_effect=command), patch.object(mac, 'stop'), patch.object(mac.subprocess, 'run') as reopen:
                with self.assertRaisesRegex(ValueError, 'Launch failed'):
                    mac.install(staged, config, job, True)
                reopen.assert_called_once()
            self.assertEqual((app / 'Contents/MacOS/Fixture').read_bytes(), b'previous')
            self.assertNotEqual(mac.read(job)['state'], 'succeeded')

    def test_interrupted_install_does_not_claim_success_without_readback(self):
        with tempfile.TemporaryDirectory() as folder:
            app, staged, job, config = self.fixture(folder)
            mac.update(job, pid=12345, phase='installing', executableDigest=mac.digest(staged))
            with patch.object(mac.os, 'kill', side_effect=ProcessLookupError), patch.object(mac, 'verify'):
                self.assertEqual(mac.status(job)['state'], 'unknownCompletion')
            self.assertEqual((app / 'Contents/MacOS/Fixture').read_bytes(), b'previous')

    def test_interrupted_install_can_confirm_matching_binary_and_process(self):
        with tempfile.TemporaryDirectory() as folder:
            app, _, job, _ = self.fixture(folder)
            mac.update(job, pid=12345, phase='launching', executableDigest=mac.digest(app))
            with patch.object(mac.os, 'kill', side_effect=ProcessLookupError), patch.object(mac, 'verify'), patch.object(mac, 'processes', return_value=[(7, app, mac.info(app))]):
                self.assertEqual(mac.status(job)['state'], 'succeeded')

    def test_cancel_is_blocked_during_replacement(self):
        with tempfile.TemporaryDirectory() as folder:
            _, _, job, _ = self.fixture(folder)
            mac.update(job, phase='installing')
            with patch.object(mac.os, 'killpg') as kill:
                with self.assertRaisesRegex(ValueError, 'replaced'):
                    mac.cancel(job)
                kill.assert_not_called()

    def test_inspection_adopts_running_swift_app_path_identity_and_metadata(self):
        with tempfile.TemporaryDirectory() as folder:
            app, _, _, _ = self.fixture(folder)
            package = Path(folder) / 'Package'
            package.mkdir(); (package / 'Package.swift').touch()
            metadata = mac.info(app); metadata['NSLocalNetworkUsageDescription'] = 'Pair with your phone.'
            (app / 'Contents/Info.plist').write_bytes(plistlib.dumps(metadata))
            def command(args, cwd=None):
                if args[0] == '/usr/bin/git':
                    if '--show-toplevel' in args: return folder
                    if '--show-current' in args: return 'main'
                    return 'a' * 40
                return json.dumps(dict(products=[dict(name='Fixture', type=dict(executable=None))]))
            with patch.object(mac, 'run', side_effect=command), patch.object(mac, 'processes', return_value=[(7, app, metadata)]), patch.object(mac, 'signature', return_value=('A' * 40, 'original')), patch.object(mac, 'select_certificate', return_value='A' * 40):
                config = mac.inspect(dict(project=str(package / 'Package.swift'), scheme='Fixture'))
                self.assertEqual(config['installPath'], str(app))
                self.assertEqual(config['bundleID'], 'test.fixture.mac')
                self.assertEqual(config['requirement'], 'original')
                self.assertEqual(config['infoPlist']['NSLocalNetworkUsageDescription'], 'Pair with your phone.')
                with self.assertRaisesRegex(ValueError, 'current path'):
                    mac.inspect(dict(project=str(package), scheme='Fixture', installPath=str(Path(folder) / 'Another.app')))

    def test_journal_files_are_private(self):
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder) / 'job.json'
            mac.write(path, dict(state='running'))
            self.assertEqual(path.stat().st_mode & 0o777, 0o600)


if __name__ == '__main__':
    unittest.main()
