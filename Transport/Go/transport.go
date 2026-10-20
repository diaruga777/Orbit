package main

import (
	"context"
	"crypto/tls"
	"encoding/json"
	"errors"
	"fmt"
	"net"
	"net/url"
	"strconv"
	"strings"
	"sync"
)

// --- dialing ---

// parseTCPAddress turns `tcp://host[:port]` into a dial address.
func parseTCPAddress(raw string) (string, error) {
	u, err := url.Parse(raw)
	if err != nil {
		return "", fmt.Errorf("address: %w", err)
	}
	switch u.Scheme {
	case "tcp", "tcp4", "tcp6":
	default:
		return "", fmt.Errorf("address: unsupported scheme %q", u.Scheme)
	}
	if u.Hostname() == "" {
		return "", fmt.Errorf("address: no host in %q", raw)
	}
	port := u.Port()
	if port == "" {
		port = "22000"
	}
	return net.JoinHostPort(u.Hostname(), port), nil
}

// dialBEP opens an authenticated BEP connection to peer at addressURL.
// A non-zero tailnet handle routes a tcp:// address through tsnet.
func dialBEP(ctx context.Context, ident *identity, addressURL string, peer deviceID, tailnetHandle int) (*tls.Conn, deviceID, error) {
	if strings.HasPrefix(addressURL, "relay://") {
		return dialViaRelay(ctx, addressURL, ident, peer)
	}
	hostport, err := parseTCPAddress(addressURL)
	if err != nil {
		return nil, deviceID{}, err
	}
	dctx, cancel := context.WithTimeout(ctx, dialTimeout)
	defer cancel()
	var raw net.Conn
	if tailnetHandle != 0 {
		server, err := lookupTailnetServer(tailnetHandle)
		if err != nil {
			return nil, deviceID{}, err
		}
		raw, err = server.Dial(dctx, "tcp", hostport)
		if err != nil {
			return nil, deviceID{}, fmt.Errorf("tailnet dial: %w", err)
		}
	} else {
		raw, err = (&net.Dialer{}).DialContext(dctx, "tcp", hostport)
		if err != nil {
			return nil, deviceID{}, fmt.Errorf("dial: %w", err)
		}
	}
	return bepHandshake(ctx, raw, ident, &peer, false)
}

// --- listeners ---

type acceptedConn struct {
	conn   *tls.Conn
	peer   deviceID
	remote string
}

// bepListener yields authenticated connections from one transport: a TCP
// or tsnet listener, or a relay join.
type bepListener struct {
	ctx       context.Context
	cancel    context.CancelFunc
	accepts   chan acceptedConn
	wg        sync.WaitGroup
	closeOnce sync.Once
	// tcp is the underlying listener for TCP and tsnet; nil for a relay.
	tcp net.Listener
	// wildcard is true for a TCP bind on an unspecified address.
	wildcard bool
	// relayURL is the sanitized relay address; empty for TCP and tsnet.
	relayURL string
	// tailnet is true for a listener on the tsnet server.
	tailnet bool
}

func newBEPListener() *bepListener {
	ctx, cancel := context.WithCancel(context.Background())
	return &bepListener{ctx: ctx, cancel: cancel, accepts: make(chan acceptedConn, 16)}
}

// deliver hands an authenticated connection to accept, or closes it when
// the listener closes first.
func (l *bepListener) deliver(ctx context.Context, c acceptedConn) {
	select {
	case l.accepts <- c:
	case <-ctx.Done():
		c.conn.Close()
	}
}

// accept blocks for the next connection. It returns errListenerClosed
// once close ran.
func (l *bepListener) accept() (acceptedConn, error) {
	select {
	case c := <-l.accepts:
		return c, nil
	case <-l.ctx.Done():
		return acceptedConn{}, errListenerClosed
	}
}

// close stops the transport, wakes blocked accept calls, and closes every
// connection nobody accepted. The transport goroutines finish in the
// background.
func (l *bepListener) close() {
	l.closeOnce.Do(func() {
		l.cancel()
		if l.tcp != nil {
			l.tcp.Close()
		}
		go func() {
			l.wg.Wait()
			for {
				select {
				case c := <-l.accepts:
					c.conn.Close()
				default:
					return
				}
			}
		}()
	})
}

// wait blocks until every transport goroutine has exited. Tests use it to
// assert the listener leaks nothing.
func (l *bepListener) wait() {
	l.wg.Wait()
}

// listenBEP starts a TLS server listener on bind ("host:port", ":port",
// or "tcp://host:port"), on tsnet when the handle is non-zero.
func listenBEP(ident *identity, bind string, tailnetHandle int) (*bepListener, error) {
	bind = strings.TrimPrefix(bind, "tcp://")
	if bind == "" {
		return nil, errors.New("listen: empty bind address")
	}
	var ln net.Listener
	var err error
	if tailnetHandle != 0 {
		server, err := lookupTailnetServer(tailnetHandle)
		if err != nil {
			return nil, err
		}
		ln, err = server.Listen("tcp", bind)
		if err != nil {
			return nil, fmt.Errorf("tailnet listen: %w", err)
		}
	} else {
		ln, err = net.Listen("tcp", bind)
		if err != nil {
			return nil, fmt.Errorf("listen: %w", err)
		}
	}
	l := newBEPListener()
	l.tcp = ln
	l.tailnet = tailnetHandle != 0
	if addr, ok := ln.Addr().(*net.TCPAddr); ok {
		l.wildcard = addr.IP == nil || addr.IP.IsUnspecified()
	}
	l.wg.Add(1)
	go l.acceptLoop(ident)
	return l, nil
}

func (l *bepListener) acceptLoop(ident *identity) {
	defer l.wg.Done()
	for {
		raw, err := l.tcp.Accept()
		if err != nil {
			if l.ctx.Err() != nil {
				return
			}
			if ne, ok := err.(net.Error); ok && ne.Timeout() {
				continue
			}
			logf("listener %s: accept failed: %v", l.tcp.Addr(), err)
			return
		}
		l.wg.Add(1)
		go func() {
			defer l.wg.Done()
			conn, peer, err := bepHandshake(l.ctx, raw, ident, nil, true)
			if err != nil {
				logf("listener %s: handshake from %s failed: %v", l.tcp.Addr(), raw.RemoteAddr(), err)
				return
			}
			l.deliver(l.ctx, acceptedConn{conn: conn, peer: peer, remote: "tcp:" + raw.RemoteAddr().String()})
		}()
	}
}

// joinRelayBEP joins a relay in permanent protocol submode (§G.4) and
// presents the invitations it receives as accepted connections.
func joinRelayBEP(ident *identity, relayURL string) (*bepListener, error) {
	u, hostport, relayID, err := parseRelayURL(relayURL)
	if err != nil {
		return nil, err
	}
	l := newBEPListener()
	l.relayURL = sanitizeRelayURL(u)
	joiner := &relayJoiner{
		listener:  l,
		ident:     ident,
		relayURL:  u,
		hostport:  hostport,
		relayID:   relayID,
		relayHost: u.Hostname(),
	}
	l.wg.Add(1)
	go joiner.run(l.ctx)
	return l, nil
}

// announceAddresses lists the Syncthing address URLs peers can reach this
// listener at. A tsnet listener announces nothing: its addresses are
// tailnet-only and dialed by host name.
func (l *bepListener) announceAddresses() []string {
	if l.relayURL != "" {
		return []string{l.relayURL}
	}
	if l.tcp == nil || l.tailnet {
		return []string{}
	}
	addr, ok := l.tcp.Addr().(*net.TCPAddr)
	if !ok {
		return []string{}
	}
	port := strconv.Itoa(addr.Port)
	if !l.wildcard {
		return []string{"tcp://" + net.JoinHostPort(addr.IP.String(), port)}
	}
	out := []string{"tcp://0.0.0.0:" + port}
	for _, ip := range interfaceIPv4s() {
		out = append(out, "tcp://"+net.JoinHostPort(ip.String(), port))
	}
	return out
}

func interfaceIPv4s() []net.IP {
	var out []net.IP
	ifaces, err := net.Interfaces()
	if err != nil {
		return out
	}
	for _, iface := range ifaces {
		if iface.Flags&net.FlagUp == 0 || iface.Flags&net.FlagLoopback != 0 {
			continue
		}
		addrs, err := iface.Addrs()
		if err != nil {
			continue
		}
		for _, a := range addrs {
			ipNet, ok := a.(*net.IPNet)
			if !ok {
				continue
			}
			ip4 := ipNet.IP.To4()
			if ip4 == nil || ip4.IsLoopback() || ip4.IsLinkLocalUnicast() {
				continue
			}
			out = append(out, ip4)
		}
	}
	return out
}

func addressesJSON(addresses []string) string {
	b, _ := json.Marshal(addresses)
	return string(b)
}
