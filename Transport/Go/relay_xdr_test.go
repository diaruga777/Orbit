package main

import (
	"bytes"
	"encoding/hex"
	"testing"
)

func mustHex(t *testing.T, s string) []byte {
	t.Helper()
	b, err := hex.DecodeString(s)
	if err != nil {
		t.Fatal(err)
	}
	return b
}

func TestOrbitNetRelayXDRHandComputedBytes(t *testing.T) {
	var id deviceID
	var key [32]byte
	for i := range id {
		id[i] = byte(i)
		key[i] = byte(0xA0 + i)
	}
	idHex := hex.EncodeToString(id[:])
	keyHex := hex.EncodeToString(key[:])
	cases := []struct {
		name string
		got  []byte
		want string
	}{
		{"Ping", encodeEmpty(relayMsgPing), "9E79BC40" + "00000000" + "00000000"},
		{"Pong", encodeEmpty(relayMsgPong), "9E79BC40" + "00000001" + "00000000"},
		{"JoinRelayRequest empty token", encodeJoinRelayRequest(""), "9E79BC40" + "00000002" + "00000004" + "00000000"},
		{"JoinRelayRequest token abc", encodeJoinRelayRequest("abc"), "9E79BC40" + "00000002" + "00000008" + "00000003" + "61626300"},
		{"JoinSessionRequest", encodeJoinSessionRequest(key), "9E79BC40" + "00000003" + "00000024" + "00000020" + keyHex},
		{"Response", encodeResponse(2, "ok"), "9E79BC40" + "00000004" + "0000000C" + "00000002" + "00000002" + "6F6B0000"},
		{"ConnectRequest", encodeConnectRequest(id), "9E79BC40" + "00000005" + "00000024" + "00000020" + idHex},
		{"SessionInvitation", encodeSessionInvitation(sessionInvitation{
			from: id, key: key, address: []byte{192, 168, 1, 10}, port: 22067, serverSocket: true,
		}), "9E79BC40" + "00000006" + "00000058" +
			"00000020" + idHex + "00000020" + keyHex +
			"00000004" + "C0A8010A" + "00005633" + "00000001"},
		{"RelayFull", encodeEmpty(relayMsgRelayFull), "9E79BC40" + "00000007" + "00000000"},
	}
	for _, c := range cases {
		if want := mustHex(t, c.want); !bytes.Equal(c.got, want) {
			t.Errorf("%s:\n got %X\nwant %X", c.name, c.got, want)
		}
		frame, err := readRelayFrame(bytes.NewReader(c.got))
		if err != nil {
			t.Errorf("%s: read back: %v", c.name, err)
			continue
		}
		if !bytes.Equal(encodeRelayFrame(frame.typ, frame.payload), c.got) {
			t.Errorf("%s: frame round trip differs", c.name)
		}
	}

	resp, err := decodeResponse(mustHex(t, "00000002"+"00000002"+"6F6B0000"))
	if err != nil || resp.code != 2 || resp.message != "ok" {
		t.Fatalf("Response decode: %+v %v", resp, err)
	}
	inv, err := decodeSessionInvitation(mustHex(t, "00000020"+idHex+"00000020"+keyHex+"00000010"+
		"20010DB8000000000000000000000001"+"00005633"+"00000000"))
	if err != nil {
		t.Fatal(err)
	}
	if inv.from != id || inv.key != key || len(inv.address) != 16 || inv.port != 22067 || inv.serverSocket {
		t.Fatalf("SessionInvitation decode: %+v", inv)
	}
	if _, err := readRelayFrame(bytes.NewReader(mustHex(t, "DEADBEEF0000000000000000"))); err == nil {
		t.Fatal("bad magic accepted")
	}
	if _, err := readRelayFrame(bytes.NewReader(mustHex(t, "9E79BC40"+"00000000"+"00000401"))); err == nil {
		t.Fatal("oversized length accepted")
	}
	if _, err := decodeSessionInvitation(mustHex(t, "00000021"+idHex+"00")); err == nil {
		t.Fatal("33-byte From accepted")
	}
}

func TestOrbitNetRelayURLParsingAndSanitizing(t *testing.T) {
	raw := "relay://82.67.219.252:22067/?id=" + referenceDeviceID + "&pingInterval=1m0s&networkTimeout=2m0s"
	u, hostport, id, err := parseRelayURL(raw)
	if err != nil {
		t.Fatal(err)
	}
	if hostport != "82.67.219.252:22067" || id == nil || id.String() != referenceDeviceID {
		t.Fatalf("hostport %s id %v", hostport, id)
	}
	if got := sanitizeRelayURL(u); got != "relay://82.67.219.252:22067/?id="+referenceDeviceID {
		t.Fatalf("sanitized %s", got)
	}
	if _, hostport, _, err := parseRelayURL("relay://relay.example"); err != nil || hostport != "relay.example:22067" {
		t.Fatalf("default port: %s %v", hostport, err)
	}
	if _, _, _, err := parseRelayURL("tcp://1.2.3.4:22000"); err == nil {
		t.Fatal("tcp URL accepted as relay")
	}
}
