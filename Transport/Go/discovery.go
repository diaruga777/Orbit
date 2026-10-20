package main

import (
	"bytes"
	"context"
	"crypto/tls"
	"crypto/x509"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"os"
	"strconv"
	"time"
)

// Global discovery v3 (claudedocs/vault-bep-reference.md §E).

const (
	discoveryLookupURL   = "https://discovery-lookup.syncthing.net/v2/"
	discoveryAnnounceURL = "https://discovery-announce-v4.syncthing.net/v2/"
	discoveryTimeout     = 30 * time.Second
)

// discoveryRootCAs replaces the system roots for the discovery servers.
// Only tests set it, to trust an httptest server.
var discoveryRootCAs *x509.CertPool

// httpStatusError is a discovery server answer other than success, with
// the `Retry-After` seconds it carried.
type httpStatusError struct {
	status     int
	retryAfter int
}

func (e *httpStatusError) Error() string {
	return fmt.Sprintf("discovery: HTTP %d (retry after %ds)", e.status, e.retryAfter)
}

func discoveryLookupEndpoint() string {
	if v := os.Getenv("LUNABEP_DISCOVERY_URL"); v != "" {
		return v
	}
	return discoveryLookupURL
}

func discoveryAnnounceEndpoint() string {
	if v := os.Getenv("LUNABEP_ANNOUNCE_URL"); v != "" {
		return v
	}
	return discoveryAnnounceURL
}

func discoveryClient(cert *tls.Certificate) *http.Client {
	cfg := &tls.Config{MinVersion: tls.VersionTLS12, RootCAs: discoveryRootCAs}
	if cert != nil {
		cfg.Certificates = []tls.Certificate{*cert}
	}
	return &http.Client{
		Timeout:   discoveryTimeout,
		Transport: &http.Transport{TLSClientConfig: cfg, ForceAttemptHTTP2: true},
	}
}

func headerSeconds(h http.Header, name string) int {
	n, err := strconv.Atoi(h.Get(name))
	if err != nil || n < 0 {
		return 0
	}
	return n
}

// discoveryLookup GETs the addresses of id and returns the server's JSON
// body verbatim.
func discoveryLookup(ctx context.Context, id deviceID) ([]byte, error) {
	endpoint, err := url.Parse(discoveryLookupEndpoint())
	if err != nil {
		return nil, fmt.Errorf("discovery: %w", err)
	}
	q := endpoint.Query()
	q.Set("device", id.String())
	endpoint.RawQuery = q.Encode()
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, endpoint.String(), nil)
	if err != nil {
		return nil, fmt.Errorf("discovery: %w", err)
	}
	req.Header.Set("Accept", "application/json")
	resp, err := discoveryClient(nil).Do(req)
	if err != nil {
		return nil, fmt.Errorf("discovery: %w", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return nil, &httpStatusError{status: resp.StatusCode, retryAfter: headerSeconds(resp.Header, "Retry-After")}
	}
	body, err := io.ReadAll(io.LimitReader(resp.Body, 1<<20))
	if err != nil {
		return nil, fmt.Errorf("discovery: %w", err)
	}
	if !json.Valid(body) {
		return nil, errors.New("discovery: response is not JSON")
	}
	return body, nil
}

// discoveryAnnounce POSTs `{"addresses":[...]}` with the device certificate
// and returns the `Reannounce-After` seconds.
func discoveryAnnounce(ctx context.Context, ident *identity, addressesJSON []byte) (int, error) {
	var body struct {
		Addresses []string `json:"addresses"`
	}
	if err := json.Unmarshal(addressesJSON, &body); err != nil {
		return 0, fmt.Errorf("discovery: addresses: %w", err)
	}
	if len(body.Addresses) == 0 {
		return 0, errors.New("discovery: no addresses to announce")
	}
	payload, err := json.Marshal(body)
	if err != nil {
		return 0, err
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, discoveryAnnounceEndpoint(), bytes.NewReader(payload))
	if err != nil {
		return 0, fmt.Errorf("discovery: %w", err)
	}
	req.Header.Set("Content-Type", "application/json")
	resp, err := discoveryClient(&ident.cert).Do(req)
	if err != nil {
		return 0, fmt.Errorf("discovery: %w", err)
	}
	defer resp.Body.Close()
	io.Copy(io.Discard, io.LimitReader(resp.Body, 1<<16))
	if resp.StatusCode != http.StatusNoContent {
		return 0, &httpStatusError{status: resp.StatusCode, retryAfter: headerSeconds(resp.Header, "Retry-After")}
	}
	return headerSeconds(resp.Header, "Reannounce-After"), nil
}
