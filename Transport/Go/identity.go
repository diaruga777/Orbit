package main

import (
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/tls"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/pem"
	"errors"
	"fmt"
	"math"
	"math/big"
	"os"
	"path/filepath"
	"sync"
	"time"
)

// identity is the local device certificate and the ID derived from it.
type identity struct {
	cert tls.Certificate
	id   deviceID
}

const (
	identityCertFile = "cert.pem"
	identityKeyFile  = "key.pem"
	// Syncthing's own lifetime (tlsutil.go deviceCertLifetimeDays).
	identityLifetime = 20 * 365 * 24 * time.Hour
)

var identities struct {
	mu sync.Mutex
	m  map[string]*identity
}

// loadIdentity returns the identity stored in dir, creating it on first use.
// Loaded identities are cached by directory.
func loadIdentity(dir string) (*identity, error) {
	if dir == "" {
		return nil, errors.New("identity: empty directory")
	}
	identities.mu.Lock()
	defer identities.mu.Unlock()
	if ident, ok := identities.m[dir]; ok {
		return ident, nil
	}
	ident, err := loadOrCreateIdentity(dir)
	if err != nil {
		return nil, err
	}
	if identities.m == nil {
		identities.m = map[string]*identity{}
	}
	identities.m[dir] = ident
	return ident, nil
}

func loadOrCreateIdentity(dir string) (*identity, error) {
	certPath := filepath.Join(dir, identityCertFile)
	keyPath := filepath.Join(dir, identityKeyFile)
	cert, err := tls.LoadX509KeyPair(certPath, keyPath)
	if err == nil {
		return identityFromCertificate(cert)
	}
	if !errors.Is(err, os.ErrNotExist) {
		return nil, fmt.Errorf("identity: load: %w", err)
	}
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return nil, fmt.Errorf("identity: %w", err)
	}
	certPEM, keyPEM, err := generateIdentityPEM()
	if err != nil {
		return nil, err
	}
	if err := writePrivateFile(keyPath, keyPEM); err != nil {
		return nil, err
	}
	if err := writePrivateFile(certPath, certPEM); err != nil {
		return nil, err
	}
	cert, err = tls.X509KeyPair(certPEM, keyPEM)
	if err != nil {
		return nil, fmt.Errorf("identity: %w", err)
	}
	return identityFromCertificate(cert)
}

func identityFromCertificate(cert tls.Certificate) (*identity, error) {
	if len(cert.Certificate) != 1 {
		return nil, fmt.Errorf("identity: cert.pem holds %d certificates, want 1", len(cert.Certificate))
	}
	return &identity{cert: cert, id: deviceIDFromCertDER(cert.Certificate[0])}, nil
}

func writePrivateFile(path string, data []byte) error {
	f, err := os.OpenFile(path, os.O_WRONLY|os.O_CREATE|os.O_TRUNC, 0o600)
	if err != nil {
		return fmt.Errorf("identity: %w", err)
	}
	if _, err := f.Write(data); err != nil {
		f.Close()
		return fmt.Errorf("identity: %w", err)
	}
	return f.Close()
}

// generateIdentityPEM builds the same certificate shape Syncthing generates,
// on an ECDSA P-256 key.
func generateIdentityPEM() (certPEM, keyPEM []byte, err error) {
	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		return nil, nil, fmt.Errorf("identity: key: %w", err)
	}
	serial, err := rand.Int(rand.Reader, new(big.Int).SetUint64(math.MaxUint64))
	if err != nil {
		return nil, nil, fmt.Errorf("identity: serial: %w", err)
	}
	notBefore := time.Now().UTC().Truncate(24 * time.Hour)
	template := x509.Certificate{
		SerialNumber: serial,
		Subject: pkix.Name{
			CommonName:         "syncthing",
			Organization:       []string{"Syncthing"},
			OrganizationalUnit: []string{"Automatically Generated"},
		},
		DNSNames:              []string{"syncthing"},
		NotBefore:             notBefore,
		NotAfter:              notBefore.Add(identityLifetime),
		KeyUsage:              x509.KeyUsageDigitalSignature | x509.KeyUsageKeyEncipherment,
		ExtKeyUsage:           []x509.ExtKeyUsage{x509.ExtKeyUsageServerAuth, x509.ExtKeyUsageClientAuth},
		BasicConstraintsValid: true,
	}
	der, err := x509.CreateCertificate(rand.Reader, &template, &template, &key.PublicKey, key)
	if err != nil {
		return nil, nil, fmt.Errorf("identity: certificate: %w", err)
	}
	keyDER, err := x509.MarshalPKCS8PrivateKey(key)
	if err != nil {
		return nil, nil, fmt.Errorf("identity: key: %w", err)
	}
	certPEM = pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: der})
	keyPEM = pem.EncodeToMemory(&pem.Block{Type: "PRIVATE KEY", Bytes: keyDER})
	return certPEM, keyPEM, nil
}
