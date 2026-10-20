package main

import (
	"encoding/json"
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
