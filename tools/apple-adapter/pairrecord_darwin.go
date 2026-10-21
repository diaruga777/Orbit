package appleadapter

import (
	"context"
	"encoding/binary"
	"errors"
	"io"
	"net"
	"strings"
	"time"

	"howett.net/plist"
)

// ReadMacPairRecord reads an existing record from the local Apple daemon. It
// never creates a pairing, contacts a phone, exports keys to iOS, or falls back
// to another device. Only the short-lived Mac helper keeps this in memory.
func ReadMacPairRecord(ctx context.Context, deviceID string) (PairRecord, error) {
	return readMacPairRecord(ctx, deviceID, func(ctx context.Context) (net.Conn, error) {
		return (&net.Dialer{}).DialContext(ctx, "unix", "/var/run/usbmuxd")
	})
}
func readMacPairRecord(ctx context.Context, deviceID string, dial func(context.Context) (net.Conn, error)) (PairRecord, error) {
	ctx, cancel := context.WithTimeout(ctx, 10*time.Second)
	defer cancel()
	if deviceID == "" || len(deviceID) > 128 || strings.IndexFunc(deviceID, func(c rune) bool {
		return !(c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z' || c >= '0' && c <= '9' || c == '-')
	}) >= 0 {
		return PairRecord{}, errors.New("invalid physical device identity")
	}
	reply, err := muxQuery(ctx, dial, map[string]any{"MessageType": "ReadPairRecord", "PairRecordID": deviceID})
	if err != nil {
		return PairRecord{}, err
	}
	data, ok := reply["PairRecordData"].([]byte)
	if !ok || len(data) > maxPlist {
		return PairRecord{}, errors.New("existing Apple pairing record unavailable")
	}
	var record PairRecord
	if _, err = plist.Unmarshal(data, &record); err != nil {
		return PairRecord{}, errors.New("invalid existing Apple pairing record")
	}
	if record.SystemBUID == "" {
		reply, err = muxQuery(ctx, dial, map[string]any{"MessageType": "ReadBUID"})
		if err != nil {
			return PairRecord{}, err
		}
		record.SystemBUID, _ = reply["BUID"].(string)
	}
	if record.HostID == "" || record.SystemBUID == "" || len(record.HostCertificate) == 0 || len(record.HostPrivateKey) == 0 || len(record.DeviceCertificate) == 0 {
		return PairRecord{}, errors.New("incomplete existing Apple pairing record")
	}
	return record, nil
}
func muxQuery(ctx context.Context, dial func(context.Context) (net.Conn, error), request map[string]any) (map[string]any, error) {
	socket, err := dial(ctx)
	if err != nil {
		return nil, err
	}
	conn := newBoundConn(ctx, socket)
	defer conn.Close()
	request["ProgName"] = "Orbit"
	request["ClientVersionString"] = "1"
	request["kLibUSBMuxVersion"] = uint64(3)
	data, err := plist.Marshal(request, plist.XMLFormat)
	if err != nil {
		return nil, err
	}
	header := make([]byte, 16)
	binary.LittleEndian.PutUint32(header, uint32(len(data)+16))
	binary.LittleEndian.PutUint32(header[4:], 1)
	binary.LittleEndian.PutUint32(header[8:], 8)
	binary.LittleEndian.PutUint32(header[12:], 1)
	if _, err = io.Copy(conn, strings.NewReader(string(append(header, data...)))); err != nil {
		return nil, err
	}
	if _, err = io.ReadFull(conn, header); err != nil {
		return nil, err
	}
	size := binary.LittleEndian.Uint32(header)
	if size < 16 || size > maxPlist || binary.LittleEndian.Uint32(header[4:]) != 1 || binary.LittleEndian.Uint32(header[8:]) != 8 || binary.LittleEndian.Uint32(header[12:]) != 1 {
		return nil, errors.New("invalid Apple pairing daemon response")
	}
	data = make([]byte, size-16)
	if _, err = io.ReadFull(conn, data); err != nil {
		return nil, err
	}
	var reply map[string]any
	if _, err = plist.Unmarshal(data, &reply); err != nil {
		return nil, errors.New("invalid Apple pairing daemon plist")
	}
	return reply, nil
}

// ExportMacPairRecord is an explicit setup-only operation. The caller chooses
// one phone and writes the result to a new owner-only file for manual import.
// It is never reachable through the network/control RPC or installer protocol.
func ExportMacPairRecord(ctx context.Context, deviceID string) ([]byte, error) {
	_, err := ReadMacPairRecord(ctx, deviceID) // validates identity and existing trust
	if err != nil {
		return nil, err
	}
	return exportMacPairRecord(ctx, deviceID, func(ctx context.Context) (net.Conn, error) {
		return (&net.Dialer{}).DialContext(ctx, "unix", "/var/run/usbmuxd")
	})
}
func exportMacPairRecord(ctx context.Context, deviceID string, dial func(context.Context) (net.Conn, error)) ([]byte, error) {
	reply, err := muxQuery(ctx, dial, map[string]any{"MessageType": "ReadPairRecord", "PairRecordID": deviceID})
	if err != nil {
		return nil, err
	}
	data, ok := reply["PairRecordData"].([]byte)
	if !ok || len(data) > maxPlist {
		return nil, errors.New("existing pairing record unavailable")
	}
	var value map[string]any
	if _, err = plist.Unmarshal(data, &value); err != nil {
		return nil, errors.New("invalid pairing record")
	}
	if old, ok := value["UDID"].(string); ok && old != "" && old != deviceID {
		return nil, errors.New("pairing record belongs to another phone")
	}
	value["UDID"] = deviceID
	if value["SystemBUID"] == nil || value["SystemBUID"] == "" {
		reply, err = muxQuery(ctx, dial, map[string]any{"MessageType": "ReadBUID"})
		if err != nil {
			return nil, err
		}
		value["SystemBUID"] = reply["BUID"]
	}
	for _, key := range []string{"HostID", "SystemBUID", "WiFiMACAddress"} {
		if text, ok := value[key].(string); !ok || text == "" {
			return nil, errors.New("complete phone pairing record unavailable: " + key)
		}
	}
	for _, key := range []string{"HostCertificate", "HostPrivateKey", "RootCertificate", "RootPrivateKey", "DeviceCertificate", "EscrowBag"} {
		if bytes, ok := value[key].([]byte); !ok || len(bytes) == 0 {
			return nil, errors.New("complete phone pairing record unavailable: " + key)
		}
	}
	return plist.Marshal(value, plist.XMLFormat)
}
