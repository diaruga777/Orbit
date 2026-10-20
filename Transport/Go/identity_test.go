package main

import (
	"bytes"
	"crypto/x509"
	"os"
	"path/filepath"
	"testing"
)

func TestOrbitNetIdentityCreateThenLoad(t *testing.T) {
	dir := filepath.Join(t.TempDir(), "identity")
	created, err := loadOrCreateIdentity(dir)
	if err != nil {
		t.Fatal(err)
	}
	loaded, err := loadOrCreateIdentity(dir)
	if err != nil {
		t.Fatal(err)
	}
	if created.id != loaded.id {
		t.Fatalf("IDs differ: %s vs %s", created.id, loaded.id)
	}
	if !bytes.Equal(created.cert.Certificate[0], loaded.cert.Certificate[0]) {
		t.Fatal("DER differs between create and load")
	}
	cert, err := x509.ParseCertificate(loaded.cert.Certificate[0])
	if err != nil {
		t.Fatal(err)
	}
	if cert.Subject.CommonName != "syncthing" || len(cert.DNSNames) != 1 || cert.DNSNames[0] != "syncthing" {
		t.Fatalf("subject %v SANs %v", cert.Subject, cert.DNSNames)
	}
	if cert.PublicKeyAlgorithm != x509.ECDSA {
		t.Fatalf("key algorithm %v", cert.PublicKeyAlgorithm)
	}
	for _, name := range []string{identityCertFile, identityKeyFile} {
		info, err := os.Stat(filepath.Join(dir, name))
		if err != nil {
			t.Fatal(err)
		}
		if info.Mode().Perm() != 0o600 {
			t.Fatalf("%s mode %o", name, info.Mode().Perm())
		}
	}
	info, err := os.Stat(dir)
	if err != nil {
		t.Fatal(err)
	}
	if info.Mode().Perm() != 0o700 {
		t.Fatalf("dir mode %o", info.Mode().Perm())
	}
}
