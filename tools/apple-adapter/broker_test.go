package appleadapter

import (
	"context"
	"encoding/binary"
	"encoding/json"
	"io"
	"net"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func TestPrivateBrokerHandshakeCarriesTypedEndpointThenOpaqueBytes(t *testing.T) {
	root, err := os.MkdirTemp("/tmp", "lcab-")
	if err != nil {
		t.Fatal(err)
	}
	defer os.RemoveAll(root)
	path := filepath.Join(root, "b.sock")
	listener, err := net.Listen("unix", path)
	if err != nil {
		t.Fatal(err)
	}
	defer listener.Close()
	done := make(chan error, 1)
	go func() {
		conn, err := listener.Accept()
		if err != nil {
			done <- err
			return
		}
		defer conn.Close()
		header := make([]byte, 8)
		_, err = io.ReadFull(conn, header)
		if err != nil {
			done <- err
			return
		}
		if string(header[:4]) != "LCA1" || binary.BigEndian.Uint32(header[4:]) > 1024 {
			done <- io.ErrUnexpectedEOF
			return
		}
		body := make([]byte, binary.BigEndian.Uint32(header[4:]))
		_, err = io.ReadFull(conn, body)
		if err != nil {
			done <- err
			return
		}
		var value map[string]any
		err = json.Unmarshal(body, &value)
		if err != nil || value["fullCloseOnEOF"] != true || value["service"] != "afc" || value["port"] != float64(32100) || value["token"] != strings.Repeat("t", 32) {
			done <- io.ErrUnexpectedEOF
			return
		}
		_, err = conn.Write([]byte{1})
		if err == nil {
			data := make([]byte, 4)
			_, err = io.ReadFull(conn, data)
			if err == nil {
				_, err = conn.Write(data)
			}
		}
		done <- err
	}()
	ctx, cancel := context.WithTimeout(context.Background(), time.Second)
	defer cancel()
	conn, err := BrokerDialer(path, strings.Repeat("t", 32))(ctx, AFC, 32100)
	if err != nil {
		t.Fatal(err)
	}
	defer conn.Close()
	if _, err = conn.Write([]byte{0, 255, 42, 7}); err != nil {
		t.Fatal(err)
	}
	reply := make([]byte, 4)
	if _, err = io.ReadFull(conn, reply); err != nil {
		t.Fatal(err)
	}
	if string(reply) != string([]byte{0, 255, 42, 7}) {
		t.Fatal(reply)
	}
	if err = <-done; err != nil {
		t.Fatal(err)
	}
}
func TestBrokerRejectsUnknownServiceBeforeDial(t *testing.T) {
	_, err := BrokerDialer("/nonexistent/private.sock", strings.Repeat("t", 32))(context.Background(), Service("arbitrary-host"), 80)
	if err == nil || !strings.Contains(err.Error(), "invalid Apple broker request") {
		t.Fatal(err)
	}
}
