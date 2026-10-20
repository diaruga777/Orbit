package appleadapter

import (
	"bytes"
	"context"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/tls"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/binary"
	"encoding/pem"
	"io"
	"math/big"
	"net"
	"os"
	"path/filepath"
	"sync"
	"testing"
	"time"
)

func identity(t *testing.T, name string) ([]byte, []byte, tls.Certificate) {
	t.Helper()
	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	template := &x509.Certificate{SerialNumber: big.NewInt(time.Now().UnixNano()), Subject: pkix.Name{CommonName: name}, NotBefore: time.Now().Add(-time.Hour), NotAfter: time.Now().Add(time.Hour), KeyUsage: x509.KeyUsageDigitalSignature, ExtKeyUsage: []x509.ExtKeyUsage{x509.ExtKeyUsageServerAuth, x509.ExtKeyUsageClientAuth}}
	der, err := x509.CreateCertificate(rand.Reader, template, template, &key.PublicKey, key)
	if err != nil {
		t.Fatal(err)
	}
	private, err := x509.MarshalPKCS8PrivateKey(key)
	if err != nil {
		t.Fatal(err)
	}
	cert := pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: der})
	secret := pem.EncodeToMemory(&pem.Block{Type: "PRIVATE KEY", Bytes: private})
	pair, err := tls.X509KeyPair(cert, secret)
	if err != nil {
		t.Fatal(err)
	}
	return cert, secret, pair
}

type fixture struct {
	pair          PairRecord
	cert          tls.Certificate
	udid          string
	mu            sync.Mutex
	installed     bool
	brokenInstall bool
	payload       []byte
	calls         []Service
}

func setup(t *testing.T) (*fixture, Artifact) {
	host, secret, _ := identity(t, "Mac")
	device, _, cert := identity(t, "Phone")
	path := filepath.Join(t.TempDir(), "signed-fixture.ipa")
	if err := os.WriteFile(path, bytes.Repeat([]byte("fixture"), 19001), 0600); err != nil {
		t.Fatal(err)
	}
	f := &fixture{pair: PairRecord{HostID: "host", SystemBUID: "system", HostCertificate: host, HostPrivateKey: secret, DeviceCertificate: device}, cert: cert, udid: "physical-fixture"}
	return f, Artifact{DeviceID: f.udid, BundleID: "example.fixture", Version: "1.0", Build: "123", Package: path, ForwarderBundleID: "example.code"}
}
func (f *fixture) dial(_ context.Context, service Service, port uint16) (net.Conn, error) {
	f.mu.Lock()
	f.calls = append(f.calls, service)
	f.mu.Unlock()
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		return nil, err
	}
	defer listener.Close()
	client, err := net.Dial("tcp", listener.Addr().String())
	if err != nil {
		return nil, err
	}
	server, err := listener.Accept()
	if err != nil {
		client.Close()
		return nil, err
	}
	go func() {
		defer server.Close()
		switch service {
		case Lockdown:
			if port != 62078 {
				return
			}
			request, err := receivePlist(server)
			if err != nil || request["Request"] != "StartSession" || request["HostID"] != "host" {
				return
			}
			if sendPlist(server, map[string]any{"EnableSessionSSL": true, "SessionID": "session"}) != nil {
				return
			}
			secure := tls.Server(server, &tls.Config{Certificates: []tls.Certificate{f.cert}, ClientAuth: tls.RequireAnyClientCert, MinVersion: tls.VersionTLS12})
			if secure.Handshake() != nil {
				return
			}
			request, err = receivePlist(secure)
			if err != nil || request["Key"] != "UniqueDeviceID" {
				return
			}
			if sendPlist(secure, map[string]any{"Value": f.udid}) != nil {
				return
			}
			request, err = receivePlist(secure)
			if err != nil {
				return
			}
			var p uint64
			switch request["Service"] {
			case "com.apple.afc":
				p = 32100
			case "com.apple.mobile.installation_proxy":
				p = 32101
			default:
				return
			}
			_ = sendPlist(secure, map[string]any{"Port": p, "EnableServiceSSL": false})
		case Installation:
			if port != 32101 {
				return
			}
			request, err := receivePlist(server)
			if err != nil {
				return
			}
			switch request["Command"] {
			case "Lookup":
				result := map[string]any{}
				f.mu.Lock()
				installed := f.installed
				f.mu.Unlock()
				if installed {
					result["example.fixture"] = map[string]any{"CFBundleIdentifier": "example.fixture", "CFBundleShortVersionString": "1.0", "CFBundleVersion": "123"}
				}
				_ = sendPlist(server, map[string]any{"LookupResult": result, "Status": "Complete"})
			case "Install":
				f.mu.Lock()
				f.installed = true
				broken := f.brokenInstall
				f.mu.Unlock()
				if !broken {
					_ = sendPlist(server, map[string]any{"Status": "Complete"})
				}
			}
		case AFC:
			if port == 32100 {
				f.afc(server)
			}
		}
	}()
	return client, nil
}
func (f *fixture) afc(conn net.Conn) {
	for {
		h := make([]byte, 40)
		if _, err := io.ReadFull(conn, h); err != nil {
			return
		}
		whole := binary.LittleEndian.Uint64(h[8:16])
		head := binary.LittleEndian.Uint64(h[16:24])
		op := binary.LittleEndian.Uint64(h[32:40])
		if head < 40 || whole < head || whole > 128*1024 {
			return
		}
		body := make([]byte, whole-40)
		if _, err := io.ReadFull(conn, body); err != nil {
			return
		}
		responseOp := uint64(1)
		extra := make([]byte, 8)
		switch op {
		case 10:
			binary.LittleEndian.PutUint64(extra, 8) // object not found: create PublicStaging/file
		case 13:
			responseOp = 14
			binary.LittleEndian.PutUint64(extra, 1)
		case 16:
			f.mu.Lock()
			f.payload = append(f.payload, body[head-40:]...)
			f.mu.Unlock()
		case 9, 20, 8:
		default:
			return
		}
		binary.LittleEndian.PutUint64(h[8:16], uint64(40+len(extra)))
		binary.LittleEndian.PutUint64(h[16:24], uint64(40+len(extra)))
		binary.LittleEndian.PutUint64(h[32:40], responseOp)
		if _, err := conn.Write(append(h, extra...)); err != nil {
			return
		}
	}
}
func TestPinnedAppleSessionUploadsInstallsAndReadsBackExactRevision(t *testing.T) {
	f, artifact := setup(t)
	result := (Adapter{Dial: f.dial, Pair: f.pair}).Install(context.Background(), artifact)
	if result.Err != nil || !result.Confirmed || !result.HandedOff || result.Stage != "readback" {
		t.Fatalf("result: %+v", result)
	}
	wanted, _ := os.ReadFile(artifact.Package)
	f.mu.Lock()
	defer f.mu.Unlock()
	if !bytes.Equal(f.payload, wanted) {
		t.Fatalf("uploaded %d bytes, expected %d", len(f.payload), len(wanted))
	}
	if len(f.calls) != 8 {
		t.Fatalf("expected four fresh lockdown/service pairs, got %v", f.calls)
	}
}
func TestLostInstallReplyRemainsUnknownThenReadbackReconciles(t *testing.T) {
	f, artifact := setup(t)
	f.brokenInstall = true
	adapter := Adapter{Dial: f.dial, Pair: f.pair}
	first := adapter.Install(context.Background(), artifact)
	if first.Confirmed || !first.HandedOff || first.Err == nil {
		t.Fatalf("unconfirmed result: %+v", first)
	}
	second := adapter.Install(context.Background(), artifact)
	if !second.Confirmed || second.HandedOff || second.Err != nil {
		t.Fatalf("reconciliation: %+v", second)
	}
}
func TestWrongAppleUDIDOrPairedCertificateStopsBeforeServiceDial(t *testing.T) {
	for _, kind := range []string{"udid", "certificate"} {
		t.Run(kind, func(t *testing.T) {
			f, artifact := setup(t)
			if kind == "udid" {
				f.udid = "different-physical-phone"
			} else {
				f.pair.DeviceCertificate, _, _ = identity(t, "Different Phone")
			}
			result := (Adapter{Dial: f.dial, Pair: f.pair}).Install(context.Background(), artifact)
			if result.Err == nil || result.HandedOff || result.Confirmed {
				t.Fatalf("accepted wrong identity: %+v", result)
			}
			f.mu.Lock()
			defer f.mu.Unlock()
			if len(f.calls) != 1 || f.calls[0] != Lockdown {
				t.Fatal(f.calls)
			}
		})
	}
}
func TestProxySelfUpdateIsRejectedBeforeOpeningAnyStream(t *testing.T) {
	f, artifact := setup(t)
	artifact.ForwarderBundleID = artifact.BundleID
	result := (Adapter{Dial: f.dial, Pair: f.pair}).Install(context.Background(), artifact)
	if result.Err == nil || result.HandedOff || len(f.calls) != 0 {
		t.Fatalf("self-update: %+v", result)
	}
}
func TestOversizedPlistAndAFCHeadersFailBeforeAllocation(t *testing.T) {
	size := make([]byte, 4)
	binary.BigEndian.PutUint32(size, maxPlist+1)
	if _, err := receivePlist(bytes.NewReader(size)); err == nil {
		t.Fatal("accepted oversized plist")
	}
	a, b := net.Pipe()
	defer a.Close()
	defer b.Close()
	go func() {
		h := make([]byte, 40)
		binary.LittleEndian.PutUint64(h, 0x4141504c36414643)
		binary.LittleEndian.PutUint64(h[8:16], 1<<40)
		binary.LittleEndian.PutUint64(h[16:24], 48)
		binary.LittleEndian.PutUint64(h[24:32], 1)
		binary.LittleEndian.PutUint64(h[32:40], 14)
		_, _ = b.Write(h)
	}()
	bounded := &afcBoundedConn{Conn: a}
	if _, err := bounded.Read(make([]byte, 40)); err == nil {
		t.Fatal("accepted oversized AFC header")
	}
}
func TestCancellationClosesStalledAppleHandshake(t *testing.T) {
	f, artifact := setup(t)
	ctx, cancel := context.WithCancel(context.Background())
	started := make(chan struct{})
	var peer net.Conn
	dial := func(_ context.Context, _ Service, _ uint16) (net.Conn, error) {
		a, b := net.Pipe()
		peer = b
		close(started)
		return a, nil
	}
	done := make(chan Result, 1)
	go func() { done <- (Adapter{Dial: dial, Pair: f.pair}).Install(ctx, artifact) }()
	<-started
	cancel()
	defer peer.Close()
	select {
	case result := <-done:
		if result.Err == nil || result.HandedOff {
			t.Fatalf("cancel: %+v", result)
		}
	case <-time.After(time.Second):
		t.Fatal("stalled socket survived cancellation")
	}
}
