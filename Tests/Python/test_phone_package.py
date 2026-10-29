import importlib.util
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest
import zipfile

spec = importlib.util.spec_from_file_location('package_phone_source', Path(__file__).resolve().parents[2] / 'scripts/package_phone_source.py')
package_phone_source = importlib.util.module_from_spec(spec)
spec.loader.exec_module(package_phone_source)


class PhonePackageTests(unittest.TestCase):
    @unittest.skipUnless(shutil.which('ditto'), 'Requires macOS archive extraction')
    def test_versioned_framework_survives_installer_extraction(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            native = root / 'Vendor/Native.xcframework'
            framework = native / 'macos-arm64/Native.framework'
            version = framework / 'Versions/A'
            (version / 'Resources').mkdir(parents=True)
            (version / 'Resources/Info.plist').write_text('framework metadata')
            (version / 'Native').write_bytes(b'native archive fixture')
            (framework / 'Versions/Current').symlink_to('A')
            (framework / 'Resources').symlink_to('Versions/Current/Resources')
            (framework / 'Native').symlink_to('Versions/Current/Native')
            archive = root / 'source.zip'
            with zipfile.ZipFile(archive, 'w') as output:
                package_phone_source.add_native_payload(output, native, root)
            extracted = root / 'extracted'
            subprocess.run(['ditto', '-x', '-k', str(archive), str(extracted)], check=True)
            restored = extracted / framework.relative_to(root)
            self.assertTrue((restored / 'Versions/Current').is_symlink())
            self.assertTrue((restored / 'Native').is_symlink())
            self.assertEqual((restored / 'Native').read_bytes(), b'native archive fixture')
            self.assertEqual((restored / 'Resources/Info.plist').read_text(), 'framework metadata')

    def test_rejects_escape_absolute_dangling_and_cyclic_links(self):
        for target in ['../outside', '/etc/hosts', 'missing', 'link']:
            with self.subTest(target=target), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                source = root / 'Native.xcframework'
                source.mkdir()
                (root / 'outside').write_text('must not package')
                (source / 'link').symlink_to(target)
                with zipfile.ZipFile(root / 'source.zip', 'w') as output:
                    with self.assertRaisesRegex(RuntimeError, 'unsafe symlink'):
                        package_phone_source.add_native_payload(output, source, root)

    def test_rejects_linked_native_root(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / 'outside').mkdir()
            source = root / 'Native.xcframework'
            source.symlink_to('outside')
            with zipfile.ZipFile(root / 'source.zip', 'w') as output:
                with self.assertRaises(RuntimeError):
                    package_phone_source.add_native_payload(output, source, root)
