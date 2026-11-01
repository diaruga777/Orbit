import importlib.util
from pathlib import Path
import tempfile
import unittest
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('xcode_mac_product', ROOT / 'scripts/xcode_mac_product.py')
product = importlib.util.module_from_spec(spec)
spec.loader.exec_module(product)


class XcodeMacProductTests(unittest.TestCase):
    def fixture(self, root):
        app = root / 'Applications/Orbit Mac.app'
        (app / 'Contents/MacOS').mkdir(parents=True)
        (app / 'Contents/Info.plist').write_text('metadata')
        (app / 'Contents/MacOS/OrbitMacApp').write_text('executable')
        return app

    def test_product_launch_path_and_clean_preserve_installed_app(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            app = self.fixture(root)
            alias = root / 'DerivedData/OrbitMacInstall.app'
            (alias / 'Contents/MacOS').mkdir(parents=True)
            for _ in range(2):
                product.expose_product(alias, app)
                self.assertTrue(alias.is_symlink())
                self.assertEqual(alias.resolve(), app.resolve())
                self.assertEqual((alias / 'Contents/MacOS/OrbitMacApp').read_text(), 'executable')
            alias.unlink()  # Xcode Clean removes only the build product link.
            self.assertEqual((app / 'Contents/Info.plist').read_text(), 'metadata')

    def test_does_not_delete_installed_or_unexpected_files(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            app = self.fixture(root)
            alias = root / 'DerivedData/OrbitMacInstall.app'
            alias.mkdir(parents=True)
            (alias / 'unexpected').write_text('keep')
            for destination in [app, app.parent / 'OrbitMacInstall.app', app / 'OrbitMacInstall.app', alias]:
                with self.assertRaises(ValueError): product.expose_product(destination, app)
            self.assertEqual((alias / 'unexpected').read_text(), 'keep')
            self.assertTrue((app / 'Contents/MacOS/OrbitMacApp').exists())

    def test_missing_install_does_not_replace_previous_product(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            app = self.fixture(root)
            alias = root / 'OrbitMacInstall.app'
            alias.symlink_to(app)
            with self.assertRaises(ValueError): product.expose_product(alias, root / 'Missing.app')
            self.assertEqual(alias.resolve(), app.resolve())

    def test_run_and_profile_resolve_product_without_path_substitution(self):
        scheme = ET.parse(ROOT / 'Orbit.xcodeproj/xcshareddata/xcschemes/OrbitMac.xcscheme')
        for action in ['LaunchAction', 'ProfileAction']:
            self.assertIsNone(scheme.find(f'{action}/PathRunnable'))
            reference = scheme.find(f'{action}/BuildableProductRunnable/BuildableReference')
            self.assertEqual(reference.get('BlueprintName'), 'OrbitMacInstall')
            self.assertEqual(reference.get('BuildableName'), 'OrbitMacInstall.app')
        native = ET.parse(ROOT / 'Orbit.xcodeproj/xcshareddata/xcschemes/OrbitMacBuild.xcscheme')
        self.assertEqual(native.find('LaunchAction/BuildableProductRunnable/BuildableReference').get('BuildableName'), 'OrbitMacClient.app')
