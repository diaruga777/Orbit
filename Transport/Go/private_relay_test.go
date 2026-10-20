package main

import (
	"bytes"
	"context"
	"crypto/rand"
	"crypto/tls"
	"io"
	"os"
	"strings"
	"testing"
	"time"
)

// Opt-in integration against upstream strelaysrv, never a public pool. The
// caller starts it bound to loopback with -pools ” -status-srv ” -nat=false.
func TestPrivateRelayAuthenticatedDuplex(t *testing.T) {
	relay := os.Getenv("ORBIT_TEST_PRIVATE_RELAY")
	if relay == "" {
		t.Skip("set ORBIT_TEST_PRIVATE_RELAY to an explicitly started loopback strelaysrv")
	}
	_, host, _, err := parseRelayURL(relay)
	if err != nil || !(strings.HasPrefix(host, "127.0.0.1:") || strings.HasPrefix(host, "[::1]:")) {
		t.Fatal("integration relay must be loopback")
	}
	mac, err := loadOrCreateIdentity(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	phone, err := loadOrCreateIdentity(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	listener, err := joinRelayBEP(mac, relay)
	if err != nil {
		t.Fatal(err)
	}
	defer listener.close()
	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()
	var client *tls.Conn
	for {
		client, _, err = dialViaRelay(ctx, relay, phone, mac.id)
		if err == nil {
			break
		}
		select {
		case <-ctx.Done():
			t.Fatal(err)
		case <-time.After(50 * time.Millisecond):
		}
	}
	defer client.Close()
	accepted, err := listener.accept()
	if err != nil {
		t.Fatal(err)
	}
	defer accepted.conn.Close()
	if accepted.peer != phone.id {
		t.Fatal("relay must not replace end-to-end peer identity")
	}
	payload := make([]byte, 1024*1024+17)
	if _, err = rand.Read(payload); err != nil {
		t.Fatal(err)
	}
	done := make(chan error, 1)
	go func() {
		received := make([]byte, len(payload))
		if _, err := io.ReadFull(accepted.conn, received); err != nil {
			done <- err
			return
		}
		if !bytes.Equal(payload, received) {
			done <- io.ErrUnexpectedEOF
			return
		}
		_, err := accepted.conn.Write(received)
		done <- err
	}()
	if _, err := client.Write(payload); err != nil {
		t.Fatal(err)
	}
	received := make([]byte, len(payload))
	if _, err := io.ReadFull(client, received); err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(received, payload) {
		t.Fatal("duplex payload changed")
	}
	if err := <-done; err != nil {
		t.Fatal(err)
	}
	// Cancelling a client tears down its stream; the relay is only a carrier.
	client.Close()
	accepted.conn.SetReadDeadline(time.Now().Add(2 * time.Second))
	if _, err := accepted.conn.Read(make([]byte, 1)); err == nil {
		t.Fatal("closed session remained readable")
	}
}
