package main

import (
	"crypto/x509"
	"encoding/pem"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
)

const referenceDeviceID = "MFZWI3D-BONSGYC-YLTMRWG-C43ENR5-QXGZDMM-FZWI3DP-BONSGYY-LTMRWAD"

func TestOrbitNetDeviceIDReferenceVectorRoundTrips(t *testing.T) {
	id, err := parseDeviceID(referenceDeviceID)
	if err != nil {
		t.Fatal(err)
	}
	if got := id.String(); got != referenceDeviceID {
		t.Fatalf("re-formatted %s, want %s", got, referenceDeviceID)
	}
	unchecked := strings.ReplaceAll(referenceDeviceID, "-", "")
	var b strings.Builder
	for g := 0; g < 4; g++ {
		b.WriteString(unchecked[g*14 : g*14+13])
	}
	fromUnchecked, err := parseDeviceID(b.String())
	if err != nil {
		t.Fatal(err)
	}
	if fromUnchecked != id {
		t.Fatal("52-character form decodes to a different ID")
	}
	lower := strings.ToLower(strings.ReplaceAll(referenceDeviceID, "-", " "))
	if fromLower, err := parseDeviceID(lower); err != nil || fromLower != id {
		t.Fatalf("lowercase spaced form: %v", err)
	}
	typo := strings.Replace(referenceDeviceID, "O", "0", 1)
	if fromTypo, err := parseDeviceID(typo); err != nil || fromTypo != id {
		t.Fatalf("typo repair: %v", err)
	}
	bad := []byte(referenceDeviceID)
	bad[6] = 'A' // check character of group 0 (index 6 of the dashed form)
	if _, err := parseDeviceID(string(bad)); err == nil {
		t.Fatal("corrupted check character accepted")
	}
	if _, err := parseDeviceID(referenceDeviceID[:20]); err == nil {
		t.Fatal("short input accepted")
	}
}

func TestOrbitNetDeviceIDMatchesSyncthingGenerate(t *testing.T) {
	syncthing, err := exec.LookPath("syncthing")
	if err != nil {
		t.Skip("syncthing binary not installed")
	}
	home := t.TempDir()
	out, err := exec.Command(syncthing, "generate", "--home", home).CombinedOutput()
	if err != nil {
		t.Skipf("syncthing generate failed: %v\n%s", err, out)
	}
	var printed string
	for _, line := range strings.Split(string(out), "\n") {
		if i := strings.Index(line, "Device ID: "); i >= 0 {
			printed = strings.TrimSpace(line[i+len("Device ID: "):])
		}
	}
	if printed == "" {
		t.Skipf("no device ID in syncthing output:\n%s", out)
	}
	certPEM, err := os.ReadFile(filepath.Join(home, "cert.pem"))
	if err != nil {
		t.Fatal(err)
	}
	block, _ := pem.Decode(certPEM)
	if block == nil {
		t.Fatal("cert.pem is not PEM")
	}
	if _, err := x509.ParseCertificate(block.Bytes); err != nil {
		t.Fatal(err)
	}
	if got := deviceIDFromCertDER(block.Bytes).String(); got != printed {
		t.Fatalf("computed %s, syncthing printed %s", got, printed)
	}
	parsed, err := parseDeviceID(printed)
	if err != nil {
		t.Fatal(err)
	}
	if parsed != deviceIDFromCertDER(block.Bytes) {
		t.Fatal("parsed ID differs from the hashed certificate")
	}
}
