package main

import (
	"context"
	"encoding/json"
	"errors"
	adapter "orbit/apple-adapter"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestPrivateManifestPermissionsUnknownFieldsAndSymlink(t *testing.T) {
	root := t.TempDir()
	if err := os.Chmod(root, 0700); err != nil {
		t.Fatal(err)
	}
	file := filepath.Join(root, "request.json")
	value := request{Artifact: adapter.Artifact{Package: filepath.Join(root, "fixture.ipa")}, Broker: filepath.Join(root, "broker.sock"), Token: strings.Repeat("t", 32)}
	data, _ := json.Marshal(value)
	if err := os.WriteFile(file, data, 0600); err != nil {
		t.Fatal(err)
	}
	if _, err := load(file); err != nil {
		t.Fatal(err)
	}
	if err := os.Chmod(file, 0644); err != nil {
		t.Fatal(err)
	}
	if _, err := load(file); err == nil {
		t.Fatal("accepted world-readable manifest")
	}
	os.Chmod(file, 0600)
	if err := os.WriteFile(file, append(data, []byte(" {}")...), 0600); err != nil {
		t.Fatal(err)
	}
	if _, err := load(file); err == nil {
		t.Fatal("accepted trailing input")
	}
	if err := os.WriteFile(file, []byte(`{"unexpected":true}`), 0600); err != nil {
		t.Fatal(err)
	}
	if _, err := load(file); err == nil {
		t.Fatal("accepted unknown field")
	}
	link := filepath.Join(root, "link.json")
	if err := os.Symlink(file, link); err != nil {
		t.Fatal(err)
	}
	if _, err := load(link); err == nil {
		t.Fatal("accepted request symlink")
	}
}

func TestExportFailureExplainsTrustWithoutLeakingDiagnosticsOrWritingFile(t *testing.T) {
	file := filepath.Join(t.TempDir(), "phone.mobiledevicepairing")
	read := func(ctx context.Context, device string) ([]byte, error) {
		if device != "selected-phone" {
			t.Fatal("wrong phone")
		}
		if _, ok := ctx.Deadline(); !ok {
			t.Fatal("export has no deadline")
		}
		return nil, errors.New("sensitive internal pairing diagnostic")
	}
	err := exportPairingWith([]string{"selected-phone", file}, read)
	if err == nil || !strings.Contains(err.Error(), "tap Trust") || strings.Contains(err.Error(), "sensitive") {
		t.Fatalf("unexpected recovery message: %v", err)
	}
	if _, err := os.Stat(file); !os.IsNotExist(err) {
		t.Fatal("failed export created a file")
	}
}

func TestExportWritesNewPrivateFileAndNeverOverwrites(t *testing.T) {
	file := filepath.Join(t.TempDir(), "phone.mobiledevicepairing")
	read := func(context.Context, string) ([]byte, error) { return []byte("synthetic pairing"), nil }
	if err := exportPairingWith([]string{"selected-phone", file}, read); err != nil {
		t.Fatal(err)
	}
	info, err := os.Stat(file)
	if err != nil || info.Mode().Perm() != 0600 {
		t.Fatal("pairing export is not private")
	}
	if err := exportPairingWith([]string{"selected-phone", file}, read); err == nil || !strings.Contains(err.Error(), "Couldn’t save") {
		t.Fatal("existing file was overwritten or error was not actionable")
	}
	bytes, _ := os.ReadFile(file)
	if string(bytes) != "synthetic pairing" {
		t.Fatal("existing file changed")
	}
	called := false
	invalidRead := func(context.Context, string) ([]byte, error) { called = true; return nil, nil }
	if err := exportPairingWith([]string{"", file}, invalidRead); err == nil || called {
		t.Fatal("empty phone reached pairing daemon")
	}
}
