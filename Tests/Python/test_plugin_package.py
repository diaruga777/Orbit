import importlib.util
import json
from pathlib import Path
import tempfile
import unittest

root=Path(__file__).resolve().parents[2]
spec=importlib.util.spec_from_file_location('package_plugin',root/'scripts/package_plugin.py')
module=importlib.util.module_from_spec(spec);spec.loader.exec_module(module)

class PluginPackageTests(unittest.TestCase):
    def test_each_host_gets_an_unambiguous_manifest_and_correct_launcher(self):
        with tempfile.TemporaryDirectory(prefix='orbit-plugin-') as temp:
            for host,manifest,var in [('codex','.codex-plugin','PLUGIN_ROOT'),('cursor','.cursor-plugin','CURSOR_PLUGIN_ROOT'),('claude','.claude-plugin','CLAUDE_PLUGIN_ROOT')]:
                result=module.package(host,Path(temp)/host)
                self.assertTrue((result/manifest/'plugin.json').is_file())
                self.assertEqual(len(list(result.glob('.*-plugin'))),1)
                if host=='codex':
                    server=json.loads((result/'mcp.json').read_text())['mcpServers']['orbit']
                else:
                    self.assertFalse((result/'plugin.json').exists())
                    config=json.loads((result/manifest/'plugin.json').read_text())['mcpServers']
                    server=json.loads((result/config).read_text())['mcpServers']['orbit']
                self.assertIn('${'+var+'}',server['args'][0])
                self.assertTrue((result/'scripts/run_mcp.py').is_file())
                self.assertTrue((result/'skills/orbit-setup/SKILL.md').is_file())
    def test_packaging_does_not_overwrite_an_installed_plugin(self):
        with tempfile.TemporaryDirectory(prefix='orbit-plugin-') as temp:
            existing=Path(temp)/'existing';existing.mkdir();(existing/'personal-data').write_text('keep')
            with self.assertRaises(ValueError):module.package('cursor',existing)
            self.assertEqual((existing/'personal-data').read_text(),'keep')
