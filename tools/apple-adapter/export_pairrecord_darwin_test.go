package appleadapter

import (
	"context"
	"encoding/binary"
	"howett.net/plist"
	"io"
	"net"
	"testing"
)

func TestSetupExportPreservesCompleteRecordAndRejectsAnotherPhone(t *testing.T) {
	record := map[string]any{"HostID": "host", "SystemBUID": "system", "WiFiMACAddress": "00:11:22:33:44:55"}
	for _, key := range []string{"HostCertificate", "HostPrivateKey", "RootCertificate", "RootPrivateKey", "DeviceCertificate", "EscrowBag"} {
		record[key] = []byte("fixture-" + key)
	}
	dial := func(context.Context) (net.Conn, error) {
		a, b := net.Pipe()
		go func() {
			defer b.Close()
			header := make([]byte, 16)
			if _, err := io.ReadFull(b, header); err != nil {
				return
			}
			body := make([]byte, binary.LittleEndian.Uint32(header)-16)
			if _, err := io.ReadFull(b, body); err != nil {
				return
			}
			var request map[string]any
			plist.Unmarshal(body, &request)
			if request["MessageType"] != "ReadPairRecord" || request["PairRecordID"] != "selected-phone" {
				return
			}
			data, _ := plist.Marshal(record, plist.XMLFormat)
			reply, _ := plist.Marshal(map[string]any{"PairRecordData": data}, plist.XMLFormat)
			binary.LittleEndian.PutUint32(header, uint32(len(reply)+16))
			b.Write(append(header, reply...))
		}()
		return a, nil
	}
	data, err := exportMacPairRecord(context.Background(), "selected-phone", dial)
	if err != nil {
		t.Fatal(err)
	}
	var exported map[string]any
	plist.Unmarshal(data, &exported)
	if exported["UDID"] != "selected-phone" || string(exported["RootPrivateKey"].([]byte)) != "fixture-RootPrivateKey" {
		t.Fatal("export lost required fields")
	}
	record["UDID"] = "other-phone"
	if _, err = exportMacPairRecord(context.Background(), "selected-phone", dial); err == nil {
		t.Fatal("wrong phone exported")
	}
	delete(record, "UDID")
	delete(record, "RootPrivateKey")
	if _, err = exportMacPairRecord(context.Background(), "selected-phone", dial); err == nil {
		t.Fatal("incomplete keys exported")
	}
}
