//go:build orbitnet_cgo_tests

package main

import "C"

import (
	"errors"
	"runtime"
	"strings"
	"syscall"
	"testing"
	"time"
	"unsafe"
)

// cIdentity creates an identity in a fresh directory through the export and
// returns the directory and the printed device ID.
func cIdentity(t *testing.T) (string, string) {
	t.Helper()
	dir := t.TempDir()
	cDir := C.CString(dir)
	defer C.free(unsafe.Pointer(cDir))
	var buf [128]C.char
	if code := orbitnet_identity(cDir, &buf[0], 128); code != 0 {
		t.Fatalf("orbitnet_identity: %d %s", code, cErrmsg())
	}
	return dir, C.GoString(&buf[0])
}

func cErrmsg() string {
	var buf [512]C.char
	orbitnet_errmsg(&buf[0], 512)
	return C.GoString(&buf[0])
}

func cListen(t *testing.T, dir, bind string) C.int {
	t.Helper()
	cDir, cBind := C.CString(dir), C.CString(bind)
	defer C.free(unsafe.Pointer(cDir))
	defer C.free(unsafe.Pointer(cBind))
	var listener C.int
	if code := orbitnet_listen(cDir, cBind, 0, &listener); code != 0 {
		t.Fatalf("orbitnet_listen: %d %s", code, cErrmsg())
	}
	return listener
}

func cListenerAddresses(t *testing.T, listener C.int) string {
	t.Helper()
	var buf [1024]C.char
	if code := orbitnet_listener_addresses(listener, &buf[0], 1024); code != 0 {
		t.Fatalf("orbitnet_listener_addresses: %d %s", code, cErrmsg())
	}
	return C.GoString(&buf[0])
}

func cDial(dir, address, expected string) (C.int, int, string) {
	cDir, cAddr, cID := C.CString(dir), C.CString(address), C.CString(expected)
	defer C.free(unsafe.Pointer(cDir))
	defer C.free(unsafe.Pointer(cAddr))
	defer C.free(unsafe.Pointer(cID))
	var fd C.int
	code := orbitnet_dial(cDir, cAddr, cID, 0, &fd)
	return code, int(fd), cErrmsg()
}

type cAccepted struct {
	code   C.int
	fd     int
	peer   string
	remote string
	errmsg string
}

func cAccept(listener C.int) cAccepted {
	var fd C.int
	var peer [128]C.char
	var remote [128]C.char
	code := orbitnet_accept(listener, &fd, &peer[0], 128, &remote[0], 128)
	return cAccepted{code: code, fd: int(fd), peer: C.GoString(&peer[0]), remote: C.GoString(&remote[0]), errmsg: cErrmsg()}
}

// listenerPort reads the port from the first announced address.
func listenerPort(t *testing.T, listener C.int) string {
	t.Helper()
	addrs := cListenerAddresses(t, listener)
	first := strings.Trim(strings.SplitN(strings.TrimPrefix(addrs, "["), ",", 2)[0], "\"]")
	return first[strings.LastIndex(first, ":")+1:]
}

func writeAll(t *testing.T, fd int, data []byte) {
	t.Helper()
	for len(data) > 0 {
		n, err := syscall.Write(fd, data)
		if err != nil {
			if errors.Is(err, syscall.EAGAIN) || errors.Is(err, syscall.EINTR) {
				time.Sleep(time.Millisecond)
				continue
			}
			t.Fatalf("write: %v", err)
		}
		data = data[n:]
	}
}

func readExactly(t *testing.T, fd int, n int) []byte {
	t.Helper()
	out := make([]byte, 0, n)
	buf := make([]byte, n)
	for len(out) < n {
		got, err := syscall.Read(fd, buf[:n-len(out)])
		if err != nil {
			if errors.Is(err, syscall.EINTR) || errors.Is(err, syscall.EAGAIN) {
				time.Sleep(time.Millisecond)
				continue
			}
			t.Fatalf("read: %v", err)
		}
		if got == 0 {
			t.Fatalf("EOF after %d of %d bytes", len(out), n)
		}
		out = append(out, buf[:got]...)
	}
	return out
}

// readEOF blocks until read returns 0 or an error.
func readEOF(fd int) error {
	buf := make([]byte, 64)
	for {
		n, err := syscall.Read(fd, buf)
		if err != nil {
			if errors.Is(err, syscall.EINTR) || errors.Is(err, syscall.EAGAIN) {
				time.Sleep(time.Millisecond)
				continue
			}
			return err
		}
		if n == 0 {
			return nil
		}
	}
}

func TestOrbitNetListenDialRoundTrip(t *testing.T) {
	serverDir, serverID := cIdentity(t)
	clientDir, clientID := cIdentity(t)
	if serverID == clientID {
		t.Fatal("two identities share an ID")
	}
	listener := cListen(t, serverDir, "127.0.0.1:0")
	addrs := cListenerAddresses(t, listener)
	if !strings.HasPrefix(addrs, "[\"tcp://127.0.0.1:") {
		t.Fatalf("addresses %s", addrs)
	}
	address := "tcp://127.0.0.1:" + listenerPort(t, listener)

	accepted := make(chan cAccepted, 1)
	go func() { accepted <- cAccept(listener) }()

	code, clientFD, msg := cDial(clientDir, address, serverID)
	if code != 0 {
		t.Fatalf("dial: %d %s", code, msg)
	}
	server := <-accepted
	if server.code != 0 {
		t.Fatalf("accept: %d %s", server.code, server.errmsg)
	}
	if server.peer != clientID {
		t.Fatalf("server saw peer %s, want %s", server.peer, clientID)
	}
	if !strings.HasPrefix(server.remote, "tcp:127.0.0.1:") {
		t.Fatalf("remote %q", server.remote)
	}

	payload := make([]byte, 300_000)
	for i := range payload {
		payload[i] = byte(i * 7)
	}
	go writeAll(t, clientFD, payload)
	if got := readExactly(t, server.fd, len(payload)); string(got) != string(payload) {
		t.Fatal("client→server bytes differ")
	}
	go writeAll(t, server.fd, payload[:1000])
	if got := readExactly(t, clientFD, 1000); string(got) != string(payload[:1000]) {
		t.Fatal("server→client bytes differ")
	}

	// Closing the client end ends the server's read with EOF.
	syscall.Close(clientFD)
	done := make(chan error, 1)
	go func() { done <- readEOF(server.fd) }()
	select {
	case err := <-done:
		if err != nil {
			t.Fatalf("server read after client close: %v", err)
		}
	case <-time.After(5 * time.Second):
		t.Fatal("server end did not see EOF after the client closed")
	}
	syscall.Close(server.fd)

	// A wrong expected ID fails as a mismatch and the listener stays usable.
	code, _, msg = cDial(clientDir, address, clientID)
	if code != orbitnetErrMismatch {
		t.Fatalf("dial with wrong expected ID: code %d %s", code, msg)
	}
	if !strings.Contains(msg, "expected") {
		t.Fatalf("mismatch message %q", msg)
	}

	// Closing the listener wakes a blocked accept.
	go func() { accepted <- cAccept(listener) }()
	time.Sleep(50 * time.Millisecond)
	if code := orbitnet_close_listener(listener); code != 0 {
		t.Fatalf("close: %d", code)
	}
	select {
	case a := <-accepted:
		if a.code != orbitnetErrListenerGone {
			t.Fatalf("accept after close: %d %s", a.code, a.errmsg)
		}
	case <-time.After(5 * time.Second):
		t.Fatal("accept did not wake on close")
	}
	if code := orbitnet_close_listener(listener); code != orbitnetErrBadHandle {
		t.Fatalf("second close: %d", code)
	}
	if code, _, _ := cDial(clientDir, address, serverID); code == 0 {
		t.Fatal("dial succeeded after the listener closed")
	}
}

func TestOrbitNetPeerClosingEndsCallerRead(t *testing.T) {
	serverDir, serverID := cIdentity(t)
	clientDir, _ := cIdentity(t)
	listener := cListen(t, serverDir, "127.0.0.1:0")
	defer orbitnet_close_listener(listener)
	address := "tcp://127.0.0.1:" + listenerPort(t, listener)
	accepted := make(chan cAccepted, 1)
	go func() { accepted <- cAccept(listener) }()
	code, clientFD, msg := cDial(clientDir, address, serverID)
	if code != 0 {
		t.Fatalf("dial: %d %s", code, msg)
	}
	server := <-accepted
	go writeAll(t, server.fd, []byte("last words"))
	if got := readExactly(t, clientFD, 10); string(got) != "last words" {
		t.Fatalf("got %q", got)
	}
	syscall.Close(server.fd)
	if err := readEOF(clientFD); err != nil {
		t.Fatalf("client read after peer close: %v", err)
	}
	if _, err := syscall.Write(clientFD, []byte("x")); err == nil {
		// The first write after the peer closed may still land in the
		// socket buffer; the next one must fail.
		time.Sleep(100 * time.Millisecond)
		if _, err := syscall.Write(clientFD, []byte("y")); err == nil {
			t.Fatal("write to a dead bridge succeeded twice")
		}
	}
	syscall.Close(clientFD)
}

func TestOrbitNetWildcardListenerAnnouncesInterfaceAddresses(t *testing.T) {
	dir, _ := cIdentity(t)
	listener := cListen(t, dir, ":0")
	defer orbitnet_close_listener(listener)
	addrs := cListenerAddresses(t, listener)
	if !strings.HasPrefix(addrs, "[\"tcp://0.0.0.0:") {
		t.Fatalf("addresses %s", addrs)
	}
	if strings.Contains(addrs, "127.0.0.1") {
		t.Fatalf("loopback announced: %s", addrs)
	}
}

func TestOrbitNetListenerCloseLeavesNoGoroutines(t *testing.T) {
	dir, _ := cIdentity(t)
	before := runtime.NumGoroutine()
	for i := 0; i < 5; i++ {
		l, err := listenBEP(mustIdentity(t, dir), "127.0.0.1:0", 0)
		if err != nil {
			t.Fatal(err)
		}
		l.close()
		l.wait()
	}
	deadline := time.Now().Add(3 * time.Second)
	for time.Now().Before(deadline) {
		if runtime.NumGoroutine() <= before {
			return
		}
		time.Sleep(20 * time.Millisecond)
	}
	t.Fatalf("goroutines %d before, %d after", before, runtime.NumGoroutine())
}

func mustIdentity(t *testing.T, dir string) *identity {
	t.Helper()
	ident, err := loadIdentity(dir)
	if err != nil {
		t.Fatal(err)
	}
	return ident
}

func TestOrbitNetErrorCodesForBadArguments(t *testing.T) {
	dir, id := cIdentity(t)
	if code, _, _ := cDial(dir, "quic://1.2.3.4:22000", id); code != orbitnetErrInvalid {
		t.Fatalf("quic scheme: %d", code)
	}
	if code, _, _ := cDial(dir, "tcp://127.0.0.1:1", "NOT-AN-ID"); code != orbitnetErrInvalid {
		t.Fatalf("bad ID: %d", code)
	}
	if code, _, msg := cDial(dir, "tcp://127.0.0.1:1", id); code != orbitnetErrUnreachable {
		t.Fatalf("closed port: %d %s", code, msg)
	}
	var buf [8]C.char
	cDir := C.CString(dir)
	defer C.free(unsafe.Pointer(cDir))
	if code := orbitnet_identity(cDir, &buf[0], 8); code != orbitnetErrRange {
		t.Fatalf("small buffer: %d", code)
	}
	if code := orbitnet_close_listener(999_999); code != orbitnetErrBadHandle {
		t.Fatalf("unknown listener: %d", code)
	}
}
