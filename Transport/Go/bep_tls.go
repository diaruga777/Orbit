package main

import (
	"context"
	"crypto/tls"
	"crypto/x509"
	"errors"
	"fmt"
	"net"
	"time"
)

const (
	bepALPN          = "bep/1.0"
	dialTimeout      = 10 * time.Second
	handshakeTimeout = 10 * time.Second
)

// identityMismatchError reports a peer whose certificate hash is not the
// expected device ID.
type identityMismatchError struct {
	expected deviceID
	actual   deviceID
}

func (e *identityMismatchError) Error() string {
	return fmt.Sprintf("peer is %s, expected %s", e.actual, e.expected)
}

// bepTLSConfig is Syncthing's BEP TLS configuration (§A.1). `expected` nil
// accepts any single peer certificate; the caller reads the ID afterwards.
func bepTLSConfig(ident *identity, expected *deviceID, server bool) *tls.Config {
	cfg := &tls.Config{
		MinVersion:             tls.VersionTLS13,
		NextProtos:             []string{bepALPN},
		Certificates:           []tls.Certificate{ident.cert},
		InsecureSkipVerify:     true,
		SessionTicketsDisabled: true,
		VerifyPeerCertificate: func(rawCerts [][]byte, _ [][]*x509.Certificate) error {
			if len(rawCerts) != 1 {
				return fmt.Errorf("peer sent %d certificates, want 1", len(rawCerts))
			}
			if expected != nil {
				actual := deviceIDFromCertDER(rawCerts[0])
				if actual != *expected {
					return &identityMismatchError{expected: *expected, actual: actual}
				}
			}
			return nil
		},
	}
	if server {
		cfg.ClientAuth = tls.RequireAnyClientCert
	}
	return cfg
}

// bepHandshake runs the TLS handshake with the 10 s timeout and returns the
// authenticated connection and the peer's device ID. On failure the raw
// connection is closed.
func bepHandshake(ctx context.Context, raw net.Conn, ident *identity, expected *deviceID, server bool) (*tls.Conn, deviceID, error) {
	cfg := bepTLSConfig(ident, expected, server)
	var conn *tls.Conn
	if server {
		conn = tls.Server(raw, cfg)
	} else {
		conn = tls.Client(raw, cfg)
	}
	hctx, cancel := context.WithTimeout(ctx, handshakeTimeout)
	defer cancel()
	if err := conn.HandshakeContext(hctx); err != nil {
		raw.Close()
		return nil, deviceID{}, err
	}
	state := conn.ConnectionState()
	if len(state.PeerCertificates) != 1 {
		conn.Close()
		return nil, deviceID{}, fmt.Errorf("peer sent %d certificates, want 1", len(state.PeerCertificates))
	}
	return conn, deviceIDFromCertDER(state.PeerCertificates[0].Raw), nil
}

var errListenerClosed = errors.New("listener closed")
