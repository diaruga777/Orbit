import importlib.util
from pathlib import Path
import tempfile
import unittest

spec = importlib.util.spec_from_file_location('local_identity', Path(__file__).resolve().parents[2] / 'scripts/local_identity.py')
identity = importlib.util.module_from_spec(spec)
spec.loader.exec_module(identity)


class LocalIdentityTests(unittest.TestCase):
    def test_exact_phone_identity_and_legacy_default(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            (root / 'Config').mkdir()
            config = root / 'Config/Local.xcconfig'
            with self.assertRaises(ValueError):
                identity.read_identity(root)
            config.write_text('ORBIT_BUNDLE_PREFIX = dev.test.orbit\nDEVELOPMENT_TEAM = ABCDEFGHIJ\n')
            self.assertEqual(identity.read_identity(root)['phone'], 'dev.test.orbit.ios')
            config.write_text(config.read_text() + 'ORBIT_IOS_BUNDLE_IDENTIFIER = dev.test.existing\n')
            self.assertEqual(identity.read_identity(root)['phone'], 'dev.test.existing')
            self.assertEqual(identity.read_identity(root)['prefix'], 'dev.test.orbit')

    def test_sample_and_nonliteral_values_fail_closed(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            (root / 'Config').mkdir()
            for prefix, team in [('org.example.orbit', 'ABCDEFGHIJ'), ('com.yourname.orbit', 'ABCDEFGHIJ'), ('dev.test.orbit', ''), ('$(FROM_ELSEWHERE)', 'ABCDEFGHIJ')]:
                (root / 'Config/Local.xcconfig').write_text(f'ORBIT_BUNDLE_PREFIX = {prefix}\nDEVELOPMENT_TEAM = {team}\n')
                with self.assertRaises(ValueError):
                    identity.read_identity(root)
