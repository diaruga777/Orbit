//go:build orbitnet_cgo_tests

package main

import "C"

import (
	"crypto/x509"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"unsafe"
)

func trustTestServer(t *testing.T, server *httptest.Server) {
	t.Helper()
	pool := x509.NewCertPool()
	pool.AddCert(server.Certificate())
	previous := discoveryRootCAs
	discoveryRootCAs = pool
	t.Cleanup(func() { discoveryRootCAs = previous })
}

func TestOrbitNetDiscoveryLookup(t *testing.T) {
	var seenPath string
	server := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		seenPath = r.URL.RequestURI()
		switch r.URL.Query().Get("device") {
		case referenceDeviceID:
			w.Header().Set("Content-Type", "application/json")
			io.WriteString(w, `{"seen":"2026-09-15T10:11:12Z","addresses":["tcp://192.168.1.10:22000","relay://1.2.3.4:22067/?id=`+referenceDeviceID+`"]}`)
		default:
			w.Header().Set("Retry-After", "1234")
			w.WriteHeader(http.StatusNotFound)
		}
	}))
	defer server.Close()
	trustTestServer(t, server)
	t.Setenv("LUNABEP_DISCOVERY_URL", server.URL+"/v2/")

	cID := C.CString(referenceDeviceID)
	defer C.free(unsafe.Pointer(cID))
	var buf [4096]C.char
	var retry C.int
	if code := orbitnet_lookup(cID, &buf[0], 4096, &retry); code != 0 {
		t.Fatalf("lookup: %d %s", code, cErrmsg())
	}
	if !strings.HasPrefix(seenPath, "/v2/?device="+referenceDeviceID) {
		t.Fatalf("request path %s", seenPath)
	}
	var parsed struct {
		Seen      string   `json:"seen"`
		Addresses []string `json:"addresses"`
	}
	if err := json.Unmarshal([]byte(C.GoString(&buf[0])), &parsed); err != nil {
		t.Fatal(err)
	}
	if parsed.Seen != "2026-09-15T10:11:12Z" || len(parsed.Addresses) != 2 {
		t.Fatalf("parsed %+v", parsed)
	}

	_, otherID := cIdentity(t)
	cOther := C.CString(otherID)
	defer C.free(unsafe.Pointer(cOther))
	code := orbitnet_lookup(cOther, &buf[0], 4096, &retry)
	if code != orbitnetErrHTTPBase-404 {
		t.Fatalf("404 code %d %s", code, cErrmsg())
	}
	if retry != 1234 {
		t.Fatalf("retry-after %d", retry)
	}
}

func TestOrbitNetDiscoveryAnnounce(t *testing.T) {
	var gotBody string
	var gotCert bool
	server := httptest.NewUnstartedServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		body, _ := io.ReadAll(r.Body)
		gotBody = string(body)
		gotCert = r.TLS != nil && len(r.TLS.PeerCertificates) == 1
		if !gotCert {
			w.Header().Set("Retry-After", "900")
			w.WriteHeader(http.StatusForbidden)
			return
		}
		if r.Method != http.MethodPost || r.Header.Get("Content-Type") != "application/json" {
			w.WriteHeader(http.StatusBadRequest)
			return
		}
		w.Header().Set("Reannounce-After", "2400")
		w.WriteHeader(http.StatusNoContent)
	}))
	server.TLS = &tlsConfigRequestingClientCert()
	server.StartTLS()
	defer server.Close()
	trustTestServer(t, server)
	t.Setenv("LUNABEP_ANNOUNCE_URL", server.URL+"/v2/")

	dir, _ := cIdentity(t)
	cDir := C.CString(dir)
	defer C.free(unsafe.Pointer(cDir))
	cAddrs := C.CString(`{"addresses":["tcp://0.0.0.0:22000","tcp://192.168.1.10:22000"]}`)
	defer C.free(unsafe.Pointer(cAddrs))
	var seconds C.int
	if code := orbitnet_announce(cDir, cAddrs, &seconds); code != 0 {
		t.Fatalf("announce: %d %s", code, cErrmsg())
	}
	if seconds != 2400 {
		t.Fatalf("reannounce %d", seconds)
	}
	if !gotCert || gotBody != `{"addresses":["tcp://0.0.0.0:22000","tcp://192.168.1.10:22000"]}` {
		t.Fatalf("cert %v body %s", gotCert, gotBody)
	}
	cEmpty := C.CString(`{"addresses":[]}`)
	defer C.free(unsafe.Pointer(cEmpty))
	if code := orbitnet_announce(cDir, cEmpty, &seconds); code == 0 {
		t.Fatal("empty announce accepted")
	}
}
