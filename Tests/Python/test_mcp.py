import importlib.machinery
import importlib.util
import json
import http.client
from pathlib import Path
import socket
import struct
import tempfile
import threading
import unittest
from unittest.mock import patch

path = Path(__file__).resolve().parents[2] / 'bin/orbit'
loader = importlib.machinery.SourceFileLoader('orbit_cli', str(path))
spec = importlib.util.spec_from_loader(loader.name, loader)
orbit = importlib.util.module_from_spec(spec); loader.exec_module(orbit)

class MCPTests(unittest.TestCase):
    def test_mac_update_has_fixed_source_and_separate_durable_status(self):
        tools = {t['name']:t for t in orbit.tool_specs()}
        self.assertFalse(tools['orbit_mac_update']['annotations']['readOnlyHint'])
        self.assertTrue(tools['orbit_mac_update_status']['annotations']['readOnlyHint'])
        with patch.object(orbit, 'rpc', return_value={'id':'mac-job','state':'accepted'}) as rpc:
            reply = orbit.handle_mcp({'jsonrpc':'2.0','id':1,'method':'tools/call','params':{'name':'orbit_mac_update','arguments':{}}})
            rpc.assert_called_once_with('mac_update', {})
            self.assertFalse(reply['result']['isError'])
            rpc.reset_mock()
            rejected = orbit.handle_mcp({'jsonrpc':'2.0','id':2,'method':'tools/call','params':{'name':'orbit_mac_update','arguments':{'source':'/another/repo'}}})
            self.assertTrue(rejected['result']['isError']); rpc.assert_not_called()
        with patch.object(orbit, 'rpc', return_value={}) as rpc, patch('sys.argv', ['orbit','mac-update-status']):
            orbit.main(); rpc.assert_called_once_with('mac_update_status', {})

    def test_initialize_and_tool_inventory(self):
        value = orbit.handle_mcp({'jsonrpc':'2.0','id':1,'method':'initialize','params':{'protocolVersion':'2024-11-05'}})
        self.assertEqual(value['result']['protocolVersion'],'2024-11-05')
        tools = orbit.handle_mcp({'jsonrpc':'2.0','id':2,'method':'tools/list'})['result']['tools']
        names = {t['name'] for t in tools}
        self.assertTrue({'orbit_build','orbit_add_github','orbit_schedule','orbit_add_target'} <= names)
        self.assertTrue(all('trust' in t['inputSchema']['required'] for t in tools if t['name'] in {'orbit_add_target','orbit_add_github'}))
    def test_widget_deployment_forwards_only_a_file_path(self):
        with patch.object(orbit,'rpc',return_value={'id':'trains','pendingPhoneApproval':True}) as rpc:
            result=orbit.handle_mcp({'jsonrpc':'2.0','id':1,'method':'tools/call','params':{'name':'orbit_widget_add','arguments':{'path':'/tmp/train.js'}}})
            rpc.assert_called_once_with('widget_add',{'path':'/tmp/train.js'})
            self.assertFalse(result['result']['isError'])

    def test_widget_cli_routes_the_positional_argument_as_path(self):
        with patch.object(orbit,'rpc',return_value={}) as rpc, patch('sys.argv',['orbit','widget-add','/tmp/train.js']):
            orbit.main()
            rpc.assert_called_once_with('widget_add',{'path':'/tmp/train.js'})

    def test_notifications_get_no_response(self):
        self.assertIsNone(orbit.handle_mcp({'jsonrpc':'2.0','method':'notifications/initialized'}))
    def test_unknown_tool_and_missing_fields_do_not_dispatch(self):
        with patch.object(orbit,'rpc') as rpc:
            unknown=orbit.handle_mcp({'jsonrpc':'2.0','id':1,'method':'tools/call','params':{'name':'shell'}})
            self.assertEqual(unknown['error']['code'],-32602)
            missing=orbit.handle_mcp({'jsonrpc':'2.0','id':2,'method':'tools/call','params':{'name':'orbit_add_target','arguments':{}}})
            self.assertTrue(missing['result']['isError']); rpc.assert_not_called()
    def test_build_is_forwarded_to_the_selected_target(self):
        with patch.object(orbit,'rpc',return_value={'id':'job','state':'accepted'}) as rpc:
            response=orbit.handle_mcp({'jsonrpc':'2.0','id':42,'method':'tools/call','params':{'name':'orbit_build','arguments':{'id':'selected'}}})
            rpc.assert_called_once_with('build',{'id':'selected'})
            self.assertFalse(response['result']['isError'])
    def test_socket_transport_handles_fragmented_response(self):
        with tempfile.TemporaryDirectory(prefix='orbit-') as folder:
            sock=socket.socket(socket.AF_UNIX,socket.SOCK_STREAM); sock.bind(folder+'/control.sock'); sock.listen(1)
            def serve():
                conn,_=sock.accept()
                with conn:
                    self.assertEqual(conn.recv(4),b'ORBT')
                    length,=struct.unpack('>I',conn.recv(4)); data=b''
                    while len(data)<length: data+=conn.recv(length-len(data))
                    self.assertEqual(json.loads(data)['method'],'targets')
                    payload=json.dumps({'result':[{'id':'app'}]}).encode()
                    for b in struct.pack('>I',len(payload))+payload: conn.sendall(bytes([b]))
            thread=threading.Thread(target=serve); thread.start()
            try:
                with patch.dict('os.environ',{'ORBIT_HOME':folder}): self.assertEqual(orbit.rpc('targets'),[{'id':'app'}])
            finally: thread.join(timeout=5); sock.close()
class MCPHTTPTests(unittest.TestCase):
    def setUp(self):
        self.server = orbit.MCPHTTPServer(('127.0.0.1', 0), orbit.MCPHTTPHandler)
        self.server.token = 'test-only-secret'
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()
    def tearDown(self):
        self.server.shutdown(); self.server.server_close(); self.thread.join(timeout=5)
    def request(self, value, extra=None, method='POST'):
        conn = http.client.HTTPConnection('127.0.0.1', self.server.server_port, timeout=5)
        headers = {'Authorization': 'Bearer test-only-secret', 'Content-Type': 'application/json',
                   'Accept': 'application/json, text/event-stream'}
        headers.update(extra or {})
        try:
            conn.request(method, '/mcp', json.dumps(value), headers)
            response = conn.getresponse(); data = response.read()
            return response.status, json.loads(data) if data else None
        finally:
            conn.close()
    def test_initialize_inventory_notifications_and_calls(self):
        code, reply = self.request({'jsonrpc':'2.0','id':1,'method':'initialize','params':{'protocolVersion':'2025-03-26'}})
        self.assertEqual(code, 200); self.assertEqual(reply['result']['protocolVersion'], '2025-03-26')
        code, reply = self.request({'jsonrpc':'2.0','id':2,'method':'tools/list'})
        self.assertEqual(code, 200); self.assertTrue(reply['result']['tools'])
        self.assertEqual(self.request({'jsonrpc':'2.0','method':'notifications/initialized'}), (202, None))
        with patch.object(orbit, 'rpc', return_value={'product':'Orbit'}) as rpc:
            code, reply = self.request({'jsonrpc':'2.0','id':3,'method':'tools/call','params':{'name':'orbit_status'}})
            self.assertEqual(code, 200); self.assertFalse(reply['result']['isError'])
            rpc.assert_called_once_with('status', {})
    def test_bad_parameters_reject_without_dispatch_and_server_remains_available(self):
        with patch.object(orbit, 'rpc') as rpc:
            for params in [[], None, 'invalid']:
                code, reply = self.request({'jsonrpc':'2.0','id':1,'method':'tools/call','params':params})
                self.assertEqual(code, 200); self.assertEqual(reply['error']['code'], -32602)
            rpc.assert_not_called()
        self.assertEqual(self.request({'jsonrpc':'2.0','id':2,'method':'ping'})[0], 200)

    def test_auth_origin_host_limits_and_no_event_stream(self):
        message = {'jsonrpc':'2.0','id':1,'method':'tools/list'}
        with patch.object(orbit, 'handle_mcp') as handler:
            self.assertEqual(self.request(message, {'Authorization':''})[0], 401)
            self.assertEqual(self.request(message, {'Origin':'https://untrusted.example'})[0], 403)
            self.assertEqual(self.request(message, {'Host':'untrusted.example'})[0], 403)
            self.assertEqual(self.request(message, {'Content-Length':str(orbit.MAX_BYTES + 1)})[0], 413)
            handler.assert_not_called()
        self.assertEqual(self.request(message, method='GET')[0], 405)
        self.assertEqual(self.request(message, method='DELETE')[0], 405)

if __name__=='__main__': unittest.main()

class AppletContractTests(unittest.TestCase):
    def test_applet_tools_forward_export_and_reject_unknown_args(self):
        params = {'destination':'/tmp/MyApplet','bundleID':'com.example.myapplet','iconPath':'/tmp/icon.png'}
        with patch.object(orbit,'rpc',return_value={}) as rpc:
            reply = orbit.handle_mcp({'jsonrpc':'2.0','id':1,'method':'tools/call','params':{'name':'orbit_applet_export','arguments':params}})
            rpc.assert_called_once_with('applet_export',params)
            self.assertFalse(reply['result']['isError'])
        names = {s['name']:s for s in orbit.tool_specs()}
        self.assertTrue(names['orbit_applet_prompt']['annotations']['readOnlyHint'])
        self.assertTrue(names['orbit_diagnostics']['annotations']['readOnlyHint'])
        self.assertIn('phone', names['orbit_diagnostics']['inputSchema']['properties'])
        self.assertIn('app', names['orbit_diagnostics']['inputSchema']['properties'])
        self.assertTrue(names['orbit_debug_setup']['annotations']['readOnlyHint'])
        self.assertIn('orbit_applet_add', names)

    def test_applet_export_cli_accepts_blank_or_file(self):
        for source in [[], ['/tmp/app.js']]:
            args = ['orbit','applet-export',*source,'--destination','/tmp/App','--bundle-id','com.example.app']
            with patch.object(orbit,'rpc',return_value={}) as rpc, patch('sys.argv',args):
                orbit.main()
                expected = {'destination':'/tmp/App','bundleID':'com.example.app'}
                if source: expected['path'] = source[0]
                rpc.assert_called_once_with('applet_export',expected)
