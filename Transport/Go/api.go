package main

import (
	"context"
	"errors"
	"log"
	"os"
	"sync"
	"syscall"
)

// The Go-typed operations behind the C exports. Tests drive these.

var orbitnetLogger = log.New(os.Stderr, "orbitnet: ", log.LstdFlags|log.LUTC)

func logf(format string, args ...any) {
	orbitnetLogger.Printf(format, args...)
}

// listeners is the registry orbitnet_listen / orbitnet_relay_join hand out
// small integer ids from.
var orbitnetListeners struct {
	mu   sync.Mutex
	next int
	m    map[int]*bepListener
}

func registerListener(l *bepListener) int {
	orbitnetListeners.mu.Lock()
	defer orbitnetListeners.mu.Unlock()
	if orbitnetListeners.m == nil {
		orbitnetListeners.m = map[int]*bepListener{}
		orbitnetListeners.next = 1
	}
	id := orbitnetListeners.next
	orbitnetListeners.next++
	orbitnetListeners.m[id] = l
	return id
}

func lookupListener(id int) (*bepListener, error) {
	orbitnetListeners.mu.Lock()
	defer orbitnetListeners.mu.Unlock()
	l := orbitnetListeners.m[id]
	if l == nil {
		return nil, withCode(codeErrBadHandle, errors.New("unknown listener"))
	}
	return l, nil
}

func unregisterListener(id int) (*bepListener, error) {
	orbitnetListeners.mu.Lock()
	defer orbitnetListeners.mu.Unlock()
	l := orbitnetListeners.m[id]
	if l == nil {
		return nil, withCode(codeErrBadHandle, errors.New("unknown listener"))
	}
	delete(orbitnetListeners.m, id)
	return l, nil
}

func identityForDir(dir string) (*identity, error) {
	ident, err := loadIdentity(dir)
	if err != nil {
		return nil, withCode(codeErrIdentity, err)
	}
	return ident, nil
}

func apiIdentity(dir string) (string, error) {
	ident, err := identityForDir(dir)
	if err != nil {
		return "", err
	}
	return ident.id.String(), nil
}

func apiDial(dir, addressURL, expectedDeviceID string, tailnetHandle int) (int, error) {
	ident, err := identityForDir(dir)
	if err != nil {
		return -1, err
	}
	peer, err := parseDeviceID(expectedDeviceID)
	if err != nil {
		return -1, withCode(codeErrInvalid, err)
	}
	conn, _, err := dialBEP(context.Background(), ident, addressURL, peer, tailnetHandle)
	if err != nil {
		return -1, err
	}
	fd, err := bridgeToSocketpair(conn)
	if err != nil {
		conn.Close()
		return -1, err
	}
	return fd, nil
}

// apiLookup returns the discovery JSON, or the Retry-After seconds with
// the error.
func apiLookup(deviceIDText string) (string, int, error) {
	id, err := parseDeviceID(deviceIDText)
	if err != nil {
		return "", 0, withCode(codeErrInvalid, err)
	}
	body, err := discoveryLookup(context.Background(), id)
	if err != nil {
		var status *httpStatusError
		if errors.As(err, &status) {
			return "", status.retryAfter, err
		}
		return "", 0, err
	}
	return string(body), 0, nil
}

// apiAnnounce returns the Reannounce-After seconds, or the Retry-After
// seconds with the error.
func apiAnnounce(dir, addressesJSON string) (int, error) {
	ident, err := identityForDir(dir)
	if err != nil {
		return 0, err
	}
	seconds, err := discoveryAnnounce(context.Background(), ident, []byte(addressesJSON))
	if err != nil {
		var status *httpStatusError
		if errors.As(err, &status) {
			return status.retryAfter, err
		}
		return 0, err
	}
	return seconds, nil
}

func apiListen(dir, bindAddress string, tailnetHandle int) (int, error) {
	ident, err := identityForDir(dir)
	if err != nil {
		return 0, err
	}
	l, err := listenBEP(ident, bindAddress, tailnetHandle)
	if err != nil {
		return 0, err
	}
	return registerListener(l), nil
}

func apiRelayJoin(dir, relayURL string) (int, error) {
	ident, err := identityForDir(dir)
	if err != nil {
		return 0, err
	}
	l, err := joinRelayBEP(ident, relayURL)
	if err != nil {
		return 0, withCode(codeErrInvalid, err)
	}
	return registerListener(l), nil
}

func apiRelayPick() (string, error) {
	return pickRelay(context.Background())
}

type acceptResult struct {
	fd     int
	peer   string
	remote string
}

func apiAccept(listenerID int) (acceptResult, error) {
	l, err := lookupListener(listenerID)
	if err != nil {
		return acceptResult{}, err
	}
	c, err := l.accept()
	if err != nil {
		return acceptResult{}, err
	}
	fd, err := bridgeToSocketpair(c.conn)
	if err != nil {
		c.conn.Close()
		return acceptResult{}, err
	}
	return acceptResult{fd: fd, peer: c.peer.String(), remote: c.remote}, nil
}

func apiListenerAddresses(listenerID int) (string, error) {
	l, err := lookupListener(listenerID)
	if err != nil {
		return "", err
	}
	return addressesJSON(l.announceAddresses()), nil
}

func apiCloseListener(listenerID int) error {
	l, err := unregisterListener(listenerID)
	if err != nil {
		return err
	}
	l.close()
	return nil
}

func closeFD(fd int) {
	syscall.Close(fd)
}
