package main

import (
	"context"
	"crypto/tls"
	"crypto/x509"
	"encoding/binary"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	mrand "math/rand/v2"
	"net"
	"net/http"
	"net/url"
	"os"
	"sort"
	"strconv"
	"sync"
	"time"
)

// Relay protocol v1 (claudedocs/vault-bep-reference.md §G).

const (
	relayMagic         = 0x9E79BC40
	relayALPN          = "bep-relay"
	relayDefaultPort   = "22067"
	relayMaxPayload    = 1024
	relayMessageWait   = 2 * time.Minute
	relayInviteTimeout = 10 * time.Second
	relayBackoffStart  = 10 * time.Second
	relayBackoffCap    = 5 * time.Minute
	relayPoolURL       = "https://relays.syncthing.net/endpoint"
	relayProbeLimit    = 16
	relayProbeTimeout  = 3 * time.Second
)

const (
	relayMsgPing               int32 = 0
	relayMsgPong               int32 = 1
	relayMsgJoinRelayRequest   int32 = 2
	relayMsgJoinSessionRequest int32 = 3
	relayMsgResponse           int32 = 4
	relayMsgConnectRequest     int32 = 5
	relayMsgSessionInvitation  int32 = 6
	relayMsgRelayFull          int32 = 7
)

const (
	relayResponseSuccess          int32 = 0
	relayResponseNotFound         int32 = 1
	relayResponseAlreadyConnected int32 = 2
	relayResponseWrongToken       int32 = 3
)

type relayFrame struct {
	typ     int32
	payload []byte
}

type relayResponse struct {
	code    int32
	message string
}

type sessionInvitation struct {
	from         deviceID
	key          [32]byte
	address      []byte
	port         uint16
	serverSocket bool
}

// relayError is a protocol-level refusal: a Response with a non-zero code
// or a RelayFull.
type relayError struct {
	code    int32
	message string
}

func (e *relayError) Error() string {
	if e.code < 0 {
		return "relay full"
	}
	return fmt.Sprintf("relay refused: code %d %q", e.code, e.message)
}

// --- XDR ---

type xdrWriter struct{ buf []byte }

func (w *xdrWriter) u32(v uint32) {
	w.buf = binary.BigEndian.AppendUint32(w.buf, v)
}

func (w *xdrWriter) opaque(b []byte) {
	w.u32(uint32(len(b)))
	w.buf = append(w.buf, b...)
	for pad := (4 - len(b)%4) % 4; pad > 0; pad-- {
		w.buf = append(w.buf, 0)
	}
}

func (w *xdrWriter) boolean(v bool) {
	if v {
		w.u32(1)
	} else {
		w.u32(0)
	}
}

type xdrReader struct {
	buf []byte
	err error
}

func (r *xdrReader) u32() uint32 {
	if r.err != nil {
		return 0
	}
	if len(r.buf) < 4 {
		r.err = io.ErrUnexpectedEOF
		return 0
	}
	v := binary.BigEndian.Uint32(r.buf)
	r.buf = r.buf[4:]
	return v
}

func (r *xdrReader) opaque(max int) []byte {
	n := int(r.u32())
	if r.err != nil {
		return nil
	}
	if n > max {
		r.err = fmt.Errorf("xdr: field of %d bytes exceeds %d", n, max)
		return nil
	}
	padded := n + (4-n%4)%4
	if len(r.buf) < padded {
		r.err = io.ErrUnexpectedEOF
		return nil
	}
	out := append([]byte(nil), r.buf[:n]...)
	r.buf = r.buf[padded:]
	return out
}

func encodeRelayFrame(typ int32, payload []byte) []byte {
	w := xdrWriter{buf: make([]byte, 0, 12+len(payload))}
	w.u32(relayMagic)
	w.u32(uint32(typ))
	w.u32(uint32(len(payload)))
	w.buf = append(w.buf, payload...)
	return w.buf
}

func encodeJoinRelayRequest(token string) []byte {
	var w xdrWriter
	w.opaque([]byte(token))
	return encodeRelayFrame(relayMsgJoinRelayRequest, w.buf)
}

func encodeJoinSessionRequest(key [32]byte) []byte {
	var w xdrWriter
	w.opaque(key[:])
	return encodeRelayFrame(relayMsgJoinSessionRequest, w.buf)
}

func encodeConnectRequest(id deviceID) []byte {
	var w xdrWriter
	w.opaque(id[:])
	return encodeRelayFrame(relayMsgConnectRequest, w.buf)
}

func encodeResponse(code int32, message string) []byte {
	var w xdrWriter
	w.u32(uint32(code))
	w.opaque([]byte(message))
	return encodeRelayFrame(relayMsgResponse, w.buf)
}

func encodeSessionInvitation(inv sessionInvitation) []byte {
	var w xdrWriter
	w.opaque(inv.from[:])
	w.opaque(inv.key[:])
	w.opaque(inv.address)
	w.u32(uint32(inv.port))
	w.boolean(inv.serverSocket)
	return encodeRelayFrame(relayMsgSessionInvitation, w.buf)
}

func encodeEmpty(typ int32) []byte {
	return encodeRelayFrame(typ, nil)
}

func decodeResponse(payload []byte) (relayResponse, error) {
	r := xdrReader{buf: payload}
	code := int32(r.u32())
	message := r.opaque(relayMaxPayload)
	return relayResponse{code: code, message: string(message)}, r.err
}

func decodeSessionInvitation(payload []byte) (sessionInvitation, error) {
	var inv sessionInvitation
	r := xdrReader{buf: payload}
	from := r.opaque(32)
	key := r.opaque(32)
	inv.address = r.opaque(32)
	inv.port = uint16(r.u32())
	inv.serverSocket = r.u32() != 0
	if r.err != nil {
		return inv, r.err
	}
	if len(from) != 32 || len(key) != 32 {
		return inv, fmt.Errorf("xdr: invitation From/Key of %d/%d bytes", len(from), len(key))
	}
	copy(inv.from[:], from)
	copy(inv.key[:], key)
	return inv, nil
}

func readRelayFrame(r io.Reader) (relayFrame, error) {
	var header [12]byte
	if _, err := io.ReadFull(r, header[:]); err != nil {
		return relayFrame{}, err
	}
	if binary.BigEndian.Uint32(header[0:]) != relayMagic {
		return relayFrame{}, errors.New("relay: bad magic")
	}
	typ := int32(binary.BigEndian.Uint32(header[4:]))
	length := int32(binary.BigEndian.Uint32(header[8:]))
	if length < 0 || length > relayMaxPayload {
		return relayFrame{}, fmt.Errorf("relay: message length %d out of range", length)
	}
	payload := make([]byte, length)
	if _, err := io.ReadFull(r, payload); err != nil {
		return relayFrame{}, err
	}
	return relayFrame{typ: typ, payload: payload}, nil
}

// readRelayFrameTimeout reads one frame within d.
func readRelayFrameTimeout(conn net.Conn, d time.Duration) (relayFrame, error) {
	conn.SetReadDeadline(time.Now().Add(d))
	defer conn.SetReadDeadline(time.Time{})
	return readRelayFrame(conn)
}

// --- relay URLs ---

// parseRelayURL splits `relay://host:port/?id=…` into the dial address and
// the relay's device ID (nil when the URL carries none).
func parseRelayURL(raw string) (*url.URL, string, *deviceID, error) {
	u, err := url.Parse(raw)
	if err != nil {
		return nil, "", nil, fmt.Errorf("relay: %w", err)
	}
	if u.Scheme != "relay" || u.Hostname() == "" {
		return nil, "", nil, fmt.Errorf("relay: not a relay URL: %q", raw)
	}
	port := u.Port()
	if port == "" {
		port = relayDefaultPort
	}
	hostport := net.JoinHostPort(u.Hostname(), port)
	var id *deviceID
	if idText := u.Query().Get("id"); idText != "" {
		parsed, err := parseDeviceID(idText)
		if err != nil {
			return nil, "", nil, err
		}
		id = &parsed
	}
	return u, hostport, id, nil
}

// sanitizeRelayURL keeps only the `id` query parameter, as Syncthing does
// before announcing a relay address.
func sanitizeRelayURL(u *url.URL) string {
	clean := *u
	q := url.Values{}
	if id := u.Query().Get("id"); id != "" {
		q.Set("id", id)
	}
	clean.RawQuery = q.Encode()
	if clean.Path == "" {
		clean.Path = "/"
	}
	return clean.String()
}

// --- protocol mode ---

// relayProtocolConn opens the TLS protocol-mode connection to a relay (§G.2).
func relayProtocolConn(ctx context.Context, u *url.URL, hostport string, ident *identity, relayID *deviceID) (*tls.Conn, error) {
	dialer := net.Dialer{Timeout: dialTimeout}
	raw, err := dialer.DialContext(ctx, "tcp", hostport)
	if err != nil {
		return nil, fmt.Errorf("relay: %w", err)
	}
	cfg := &tls.Config{
		MinVersion:             tls.VersionTLS12,
		NextProtos:             []string{relayALPN},
		Certificates:           []tls.Certificate{ident.cert},
		InsecureSkipVerify:     true,
		SessionTicketsDisabled: true,
		ServerName:             u.Hostname(),
		VerifyPeerCertificate: func(rawCerts [][]byte, _ [][]*x509.Certificate) error {
			if relayID == nil {
				return nil
			}
			if len(rawCerts) != 1 {
				return fmt.Errorf("relay sent %d certificates, want 1", len(rawCerts))
			}
			if actual := deviceIDFromCertDER(rawCerts[0]); actual != *relayID {
				return &identityMismatchError{expected: *relayID, actual: actual}
			}
			return nil
		},
	}
	conn := tls.Client(raw, cfg)
	hctx, cancel := context.WithTimeout(ctx, handshakeTimeout)
	defer cancel()
	if err := conn.HandshakeContext(hctx); err != nil {
		raw.Close()
		return nil, fmt.Errorf("relay: %w", err)
	}
	if conn.ConnectionState().NegotiatedProtocol != relayALPN {
		conn.Close()
		return nil, errors.New("relay: protocol negotiation error")
	}
	return conn, nil
}

// relayRequestSession runs §G.5: asks the relay for a session with peer
// and returns the invitation plus the relay's IP (for an empty Address).
func relayRequestSession(ctx context.Context, relayURL string, ident *identity, peer deviceID) (sessionInvitation, net.IP, error) {
	u, hostport, relayID, err := parseRelayURL(relayURL)
	if err != nil {
		return sessionInvitation{}, nil, err
	}
	conn, err := relayProtocolConn(ctx, u, hostport, ident, relayID)
	if err != nil {
		return sessionInvitation{}, nil, err
	}
	defer conn.Close()
	conn.SetWriteDeadline(time.Now().Add(relayInviteTimeout))
	if _, err := conn.Write(encodeConnectRequest(peer)); err != nil {
		return sessionInvitation{}, nil, fmt.Errorf("relay: %w", err)
	}
	frame, err := readRelayFrameTimeout(conn, relayInviteTimeout)
	if err != nil {
		return sessionInvitation{}, nil, fmt.Errorf("relay: %w", err)
	}
	switch frame.typ {
	case relayMsgSessionInvitation:
		inv, err := decodeSessionInvitation(frame.payload)
		if err != nil {
			return sessionInvitation{}, nil, fmt.Errorf("relay: %w", err)
		}
		return inv, remoteIP(conn), nil
	case relayMsgResponse:
		resp, err := decodeResponse(frame.payload)
		if err != nil {
			return sessionInvitation{}, nil, fmt.Errorf("relay: %w", err)
		}
		return sessionInvitation{}, nil, &relayError{code: resp.code, message: resp.message}
	case relayMsgRelayFull:
		return sessionInvitation{}, nil, &relayError{code: -1}
	default:
		return sessionInvitation{}, nil, fmt.Errorf("relay: unexpected message type %d", frame.typ)
	}
}

func remoteIP(conn net.Conn) net.IP {
	if addr, ok := conn.RemoteAddr().(*net.TCPAddr); ok {
		return addr.IP
	}
	return nil
}

// relayJoinSession runs §G.6 up to the point the socket becomes a byte pipe
// to the peer: plain TCP to the session address, JoinSessionRequest, then a
// Response{0}.
func relayJoinSession(ctx context.Context, inv sessionInvitation, relayIP net.IP) (net.Conn, error) {
	ip := net.IP(inv.address)
	if len(ip) == 0 || ip.IsUnspecified() {
		ip = relayIP
	}
	if ip == nil {
		return nil, errors.New("relay: invitation without an address")
	}
	dialer := net.Dialer{Timeout: dialTimeout}
	conn, err := dialer.DialContext(ctx, "tcp", net.JoinHostPort(ip.String(), strconv.Itoa(int(inv.port))))
	if err != nil {
		return nil, fmt.Errorf("relay session: %w", err)
	}
	conn.SetWriteDeadline(time.Now().Add(relayInviteTimeout))
	if _, err := conn.Write(encodeJoinSessionRequest(inv.key)); err != nil {
		conn.Close()
		return nil, fmt.Errorf("relay session: %w", err)
	}
	conn.SetWriteDeadline(time.Time{})
	frame, err := readRelayFrameTimeout(conn, relayInviteTimeout)
	if err != nil {
		conn.Close()
		return nil, fmt.Errorf("relay session: %w", err)
	}
	switch frame.typ {
	case relayMsgResponse:
		resp, err := decodeResponse(frame.payload)
		if err != nil {
			conn.Close()
			return nil, fmt.Errorf("relay session: %w", err)
		}
		if resp.code != relayResponseSuccess {
			conn.Close()
			return nil, &relayError{code: resp.code, message: resp.message}
		}
		return conn, nil
	case relayMsgRelayFull:
		conn.Close()
		return nil, &relayError{code: -1}
	default:
		conn.Close()
		return nil, fmt.Errorf("relay session: unexpected message type %d", frame.typ)
	}
}

// dialViaRelay is the complete §G.5 + §G.6 client path ending in an
// authenticated BEP TLS connection to peer.
func dialViaRelay(ctx context.Context, relayURL string, ident *identity, peer deviceID) (*tls.Conn, deviceID, error) {
	inv, relayIP, err := relayRequestSession(ctx, relayURL, ident, peer)
	if err != nil {
		return nil, deviceID{}, err
	}
	if inv.from != peer {
		return nil, deviceID{}, &identityMismatchError{expected: peer, actual: inv.from}
	}
	raw, err := relayJoinSession(ctx, inv, relayIP)
	if err != nil {
		return nil, deviceID{}, err
	}
	return bepHandshake(ctx, raw, ident, &peer, inv.serverSocket)
}

// --- permanent protocol submode (§G.4) ---

// relayJoiner keeps one listener joined to a relay and turns every
// invitation into an accepted connection.
type relayJoiner struct {
	listener  *bepListener
	ident     *identity
	relayURL  *url.URL
	hostport  string
	relayID   *deviceID
	relayHost string
}

func (j *relayJoiner) run(ctx context.Context) {
	defer j.listener.wg.Done()
	backoff := relayBackoffStart
	for {
		joined, err := j.session(ctx)
		if ctx.Err() != nil {
			return
		}
		if joined {
			backoff = relayBackoffStart
		}
		logf("relay %s: connection ended: %v; retry in %s", j.relayHost, err, backoff)
		select {
		case <-ctx.Done():
			return
		case <-time.After(backoff):
		}
		backoff = min(backoff*2, relayBackoffCap)
	}
}

// session holds one protocol-mode connection until it fails. It reports
// whether the join succeeded so the caller can reset its backoff.
func (j *relayJoiner) session(ctx context.Context) (joined bool, err error) {
	conn, err := relayProtocolConn(ctx, j.relayURL, j.hostport, j.ident, j.relayID)
	if err != nil {
		return false, err
	}
	defer conn.Close()
	done := make(chan struct{})
	defer close(done)
	go func() {
		select {
		case <-ctx.Done():
			conn.Close()
		case <-done:
		}
	}()

	if _, err := conn.Write(encodeJoinRelayRequest("")); err != nil {
		return false, err
	}
	frame, err := readRelayFrameTimeout(conn, relayInviteTimeout)
	if err != nil {
		return false, err
	}
	switch frame.typ {
	case relayMsgResponse:
		resp, err := decodeResponse(frame.payload)
		if err != nil {
			return false, err
		}
		if resp.code != relayResponseSuccess {
			return false, &relayError{code: resp.code, message: resp.message}
		}
	case relayMsgRelayFull:
		return false, &relayError{code: -1}
	default:
		return false, fmt.Errorf("relay: unexpected message type %d after join", frame.typ)
	}
	logf("relay %s: joined", j.relayHost)
	relayIP := remoteIP(conn)

	for {
		frame, err := readRelayFrameTimeout(conn, relayMessageWait)
		if err != nil {
			return true, err
		}
		switch frame.typ {
		case relayMsgPing:
			conn.SetWriteDeadline(time.Now().Add(relayInviteTimeout))
			if _, err := conn.Write(encodeEmpty(relayMsgPong)); err != nil {
				return true, err
			}
		case relayMsgPong, relayMsgResponse:
		case relayMsgSessionInvitation:
			inv, err := decodeSessionInvitation(frame.payload)
			if err != nil {
				return true, err
			}
			j.listener.wg.Add(1)
			go j.acceptInvitation(ctx, inv, relayIP)
		case relayMsgRelayFull:
			return true, &relayError{code: -1}
		default:
			return true, fmt.Errorf("relay: unexpected message type %d", frame.typ)
		}
	}
}

func (j *relayJoiner) acceptInvitation(ctx context.Context, inv sessionInvitation, relayIP net.IP) {
	defer j.listener.wg.Done()
	// strelaysrv v1.29.7 consumes each key before a nonblocking send into
	// its session's unbuffered connection mailbox (session.go AddConnection).
	// Near-simultaneous joins can therefore refuse one valid side. Give the
	// initiator a small head start; never hold cancellation or retry a used key.
	timer := time.NewTimer(10 * time.Millisecond)
	defer timer.Stop()
	select {
	case <-ctx.Done():
		return
	case <-timer.C:
	}
	raw, err := relayJoinSession(ctx, inv, relayIP)
	if err != nil {
		logf("relay %s: session join failed: %v", j.relayHost, err)
		return
	}
	expected := inv.from
	conn, peer, err := bepHandshake(ctx, raw, j.ident, &expected, inv.serverSocket)
	if err != nil {
		logf("relay %s: handshake with %s failed: %v", j.relayHost, expected, err)
		return
	}
	j.listener.deliver(ctx, acceptedConn{conn: conn, peer: peer, remote: "relay:" + j.relayHost})
}

// --- pool ---

var relayPoolHTTPClient = &http.Client{Timeout: 30 * time.Second}

func relayPoolEndpoint() string {
	if v := os.Getenv("LUNABEP_RELAY_POOL_URL"); v != "" {
		return v
	}
	return relayPoolURL
}

// pickRelay fetches the public pool and returns the sanitized URL of the
// candidate with the lowest TCP connect latency.
func pickRelay(ctx context.Context) (string, error) {
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, relayPoolEndpoint(), nil)
	if err != nil {
		return "", err
	}
	req.Header.Set("Accept", "application/json")
	resp, err := relayPoolHTTPClient.Do(req)
	if err != nil {
		return "", fmt.Errorf("relay pool: %w", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return "", fmt.Errorf("relay pool: HTTP %d", resp.StatusCode)
	}
	var pool struct {
		Relays []struct {
			URL string `json:"url"`
		} `json:"relays"`
	}
	if err := json.NewDecoder(io.LimitReader(resp.Body, 4<<20)).Decode(&pool); err != nil {
		return "", fmt.Errorf("relay pool: %w", err)
	}
	type candidate struct {
		url      string
		hostport string
	}
	var candidates []candidate
	for _, entry := range pool.Relays {
		u, hostport, _, err := parseRelayURL(entry.URL)
		if err != nil {
			continue
		}
		candidates = append(candidates, candidate{url: sanitizeRelayURL(u), hostport: hostport})
	}
	if len(candidates) == 0 {
		return "", errors.New("relay pool: no usable relays")
	}
	mrand.Shuffle(len(candidates), func(i, k int) { candidates[i], candidates[k] = candidates[k], candidates[i] })
	if len(candidates) > relayProbeLimit {
		candidates = candidates[:relayProbeLimit]
	}
	type probe struct {
		url     string
		latency time.Duration
	}
	results := make(chan probe, len(candidates))
	var wg sync.WaitGroup
	for _, c := range candidates {
		wg.Add(1)
		go func(c candidate) {
			defer wg.Done()
			pctx, cancel := context.WithTimeout(ctx, relayProbeTimeout)
			defer cancel()
			started := time.Now()
			conn, err := (&net.Dialer{}).DialContext(pctx, "tcp", c.hostport)
			if err != nil {
				return
			}
			conn.Close()
			results <- probe{url: c.url, latency: time.Since(started)}
		}(c)
	}
	wg.Wait()
	close(results)
	var probes []probe
	for p := range results {
		probes = append(probes, p)
	}
	if len(probes) == 0 {
		return "", errors.New("relay pool: no relay answered")
	}
	sort.Slice(probes, func(i, k int) bool { return probes[i].latency < probes[k].latency })
	return probes[0].url, nil
}
