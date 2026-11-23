import os
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / 'scripts'))
import agent_identity as installer


class AgentInstallIdentityTests(unittest.TestCase):
    def setUp(self):
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        self.root = Path(temp.name)
        (self.root / 'Config').mkdir()
        self.config = self.root / 'Config/Local.xcconfig'
        self.key = ('A' * 40, 'Apple Development: Fixture', 'ABCDEFGHIJ')
        for mock in [patch.dict(os.environ, {'ORBIT_HOME': str(self.root)}, clear=True),
                     patch.object(installer.mac, 'REGISTRY', self.root / 'registry.json'),
                     patch.object(installer.mac, 'CANONICAL', self.root / 'Mac.app'),
                     patch.object(installer.mac, 'identities', return_value=[self.key])]:
            mock.start()
            self.addCleanup(mock.stop)

    def test_new_install_reuses_generated_identity_on_rerun(self):
        self.assertEqual(installer.prepare(self.root), self.key[0])
        original = self.config.read_bytes()
        self.assertEqual(self.config.stat().st_mode & 0o777, 0o600)
        self.assertEqual(installer.mac.read_identity(self.root)['team'], self.key[2])
        self.assertEqual(installer.prepare(self.root), self.key[0])
        self.assertEqual(self.config.read_bytes(), original)

    def test_existing_install_or_invalid_config_never_generates_replacement(self):
        (self.root / 'setup.json').write_text('{}')
        with self.assertRaises(ValueError):
            installer.prepare(self.root)
        self.assertFalse(self.config.exists())
        self.config.write_text('DEVELOPMENT_TEAM = YOUR_TEAM_ID')
        with self.assertRaises(ValueError):
            installer.prepare(self.root)
        self.assertEqual(self.config.read_text(), 'DEVELOPMENT_TEAM = YOUR_TEAM_ID')

    def test_multiple_certificates_require_a_choice(self):
        other = ('B' * 40, 'Apple Development: Other', 'KLMNOPQRST')
        with patch.object(installer.mac, 'identities', return_value=[self.key, other]), \
             patch.object(installer, 'choose', return_value=other) as choose:
            self.assertEqual(installer.prepare(self.root), other[0])
            choose.assert_called_once_with([self.key, other])
        self.assertEqual(installer.mac.read_identity(self.root)['team'], other[2])
