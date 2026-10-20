package appleadapter

// This opt-in fixture is compiled only into the Go test binary. It never reads
// usbmuxd/pairing records, exposes production CLI overrides or contacts a phone.
import (
	"bytes"
	"context"
	"encoding/json"
	"io"
	"net"
	"os"
	"path/filepath"
	"strconv"
	"testing"
	"time"
)

func TestSwiftPrivateRelayAppleIntegration(t *testing.T) {
	root := os.Getenv("ORBIT_TEST_APPLE_IPC")
	if root == "" {
		t.Skip("run tools/code-apple-adapter/integration/run.sh")
	}
	info, err := os.Stat(root)
	if err != nil || !info.IsDir() || info.Mode().Perm() != 0700 {
		t.Fatal("private integration directory required")
	}
	f, artifact := setup(t)
	scenario := os.Getenv("ORBIT_TEST_APPLE_SCENARIO")
	switch scenario {
	case "confirmed":
	case "lost-reply":
		f.brokenInstall = true
	case "wrong-udid":
		f.udid = "another-physical-fixture"
	case "wrong-certificate":
		f.pair.DeviceCertificate, _, _ = identity(t, "Unpaired phone")
	default:
		t.Fatal("unknown synthetic scenario")
	}
	// Map the three typed Apple services to test-only ephemeral loopback sockets.
	// Swift's endpoint factory validates service AND Apple port before using these.
	ports := map[string]int{}
	for _, entry := range []struct {
		service Service
		port    uint16
	}{{Lockdown, 62078}, {AFC, 32100}, {Installation, 32101}} {
		entry := entry
		listener, err := net.Listen("tcp4", "127.0.0.1:0")
		if err != nil {
			t.Fatal(err)
		}
		defer listener.Close()
		_, port, _ := net.SplitHostPort(listener.Addr().String())
		ports[string(entry.service)], _ = strconv.Atoi(port)
		go func() {
			for {
				peer, err := listener.Accept()
				if err != nil {
					return
				}
				go func() {
					defer peer.Close()
					endpoint, err := f.dial(context.Background(), entry.service, entry.port)
					if err != nil {
						return
					}
					defer endpoint.Close()
					done := make(chan struct{})
					go func() { _, _ = io.Copy(endpoint, peer); endpoint.Close(); close(done) }()
					_, _ = io.Copy(peer, endpoint)
					peer.Close()
					<-done
				}()
			}
		}()
	}
	data, _ := json.Marshal(ports)
	if err = os.WriteFile(filepath.Join(root, "fixture.json"), data, 0600); err != nil {
		t.Fatal(err)
	}
	var broker struct {
		Path  string `json:"path"`
		Token string `json:"token"`
	}
	deadline := time.Now().Add(30 * time.Second)
	for {
		data, err = os.ReadFile(filepath.Join(root, "broker.json"))
		if err == nil {
			if err = json.Unmarshal(data, &broker); err != nil {
				t.Fatal(err)
			}
			break
		}
		if time.Now().After(deadline) {
			t.Fatal("Swift broker did not start")
		}
		time.Sleep(10 * time.Millisecond)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 90*time.Second)
	defer cancel()
	adapter := Adapter{Dial: BrokerDialer(broker.Path, broker.Token), Pair: f.pair}
	result := adapter.Install(ctx, artifact)
	switch scenario {
	case "confirmed":
		if result.Err != nil || !result.Confirmed || !result.HandedOff || result.Stage != "readback" {
			t.Fatalf("confirmed: %+v", result)
		}
	case "lost-reply":
		if result.Err == nil || result.Confirmed || !result.HandedOff {
			t.Fatalf("unknown handoff: %+v", result)
		}
		result = adapter.Install(ctx, artifact)
		if result.Err != nil || !result.Confirmed || result.HandedOff {
			t.Fatalf("readback before replay: %+v", result)
		}
	default:
		if result.Err == nil || result.Confirmed || result.HandedOff {
			t.Fatalf("identity rejection: %+v", result)
		}
	}
	f.mu.Lock()
	defer f.mu.Unlock()
	if scenario == "confirmed" || scenario == "lost-reply" {
		wanted, _ := os.ReadFile(artifact.Package)
		if !bytes.Equal(f.payload, wanted) {
			t.Fatalf("upload changed: %d vs %d bytes", len(f.payload), len(wanted))
		}
		if len(f.calls) != 8 {
			t.Fatalf("expected eight fresh proven streams, got %v", f.calls)
		}
	} else if len(f.calls) != 1 || f.calls[0] != Lockdown {
		t.Fatalf("identity failure opened a service: %v", f.calls)
	}
}
