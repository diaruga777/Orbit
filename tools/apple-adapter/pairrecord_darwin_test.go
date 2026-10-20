package appleadapter

import (
	"context"
	"encoding/binary"
	"howett.net/plist"
	"io"
	"net"
	"testing"
)

func TestReadsOnlySelectedExistingMacPairRecord(t *testing.T) {
	f, _ := setup(t)
	record := f.pair
	record.SystemBUID = ""
	calls := 0
	dial := func(context.Context) (net.Conn, error) {
		a, b := net.Pipe()
		calls++
		go func() {
			defer b.Close()
			header := make([]byte, 16)
			if _, err := io.ReadFull(b, header); err != nil {
				return
			}
			data := make([]byte, binary.LittleEndian.Uint32(header)-16)
			if _, err := io.ReadFull(b, data); err != nil {
				return
			}
			var request map[string]any
			if _, err := plist.Unmarshal(data, &request); err != nil {
				return
			}
			var reply map[string]any
			switch request["MessageType"] {
			case "ReadPairRecord":
				if request["PairRecordID"] != "physical-fixture" {
					return
				}
				encoded, _ := plist.Marshal(record, plist.XMLFormat)
				reply = map[string]any{"PairRecordData": encoded}
			case "ReadBUID":
				reply = map[string]any{"BUID": "system"}
			default:
				return
			}
			data, _ = plist.Marshal(reply, plist.XMLFormat)
			binary.LittleEndian.PutUint32(header, uint32(len(data)+16))
			_, _ = b.Write(append(header, data...))
		}()
		return a, nil
	}
	result, err := readMacPairRecord(context.Background(), "physical-fixture", dial)
	if err != nil || result.HostID != "host" || result.SystemBUID != "system" || calls != 2 {
		t.Fatalf("record read failed; calls=%d, error=%v", calls, err)
	}
	if _, err = readMacPairRecord(context.Background(), "../other-phone", dial); err == nil || calls != 2 {
		t.Fatal("unsafe ID reached pairing daemon")
	}
}
