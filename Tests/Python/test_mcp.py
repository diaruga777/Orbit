import importlib.machinery
import importlib.util
import json
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
    def test_initialize_and_tool_inventory(self):
        value = orbit.handle_mcp({'jsonrpc':'2.0','id':1,'method':'initialize','params':{'protocolVersion':'2024-11-05'}})
        self.assertEqual(value['result']['protocolVersion'],'2024-11-05')
        tools = orbit.handle_mcp({'jsonrpc':'2.0','id':2,'method':'tools/list'})['result']['tools']
        names = {t['name'] for t in tools}
        self.assertTrue({'orbit_build','orbit_add_github','orbit_schedule','orbit_add_target'} <= names)
        self.assertTrue(all('trust' in t['inputSchema']['required'] for t in tools if t['name'] in {'orbit_add_target','orbit_add_github'}))
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
if __name__=='__main__': unittest.main()
