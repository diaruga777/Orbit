// orbitnet gives Swift authenticated plaintext BEP sockets over TLS 1.3 to
// Syncthing peers. It compiles as extra files of libtailscale's `package
// main`, so its exports land in the same C archive as `tailscale_*`. The C
// prototypes are in orbitnet.h; the Swift shim is OrbitNet. The
// operations themselves are in api.go; this file is the C boundary.
package main

/*
#include <pthread.h>
#include <stddef.h>
*/
import "C"

import (
	"errors"
	"sync"
	"unsafe"
)

// lastErrors keeps the last error message per calling OS thread. An
// exported function runs on the thread that called it, so the caller reads
// its own message back with orbitnet_errmsg on the same thread.
var lastErrors struct {
	mu sync.Mutex
	m  map[uintptr]string
}

func threadKey() uintptr {
	return uintptr(unsafe.Pointer(C.pthread_self()))
}

func setLastError(err error) {
	lastErrors.mu.Lock()
	defer lastErrors.mu.Unlock()
	if lastErrors.m == nil || len(lastErrors.m) > 256 {
		lastErrors.m = map[uintptr]string{}
	}
	if err == nil {
		delete(lastErrors.m, threadKey())
		return
	}
	lastErrors.m[threadKey()] = err.Error()
}

// finish records err for the calling thread and returns its code.
func finish(err error) C.int {
	setLastError(err)
	return C.int(errorCode(err))
}

func putCString(buf *C.char, buflen C.size_t, s string) C.int {
	if buf == nil || buflen == 0 {
		return finish(withCode(codeErrRange, errors.New("output buffer is nil")))
	}
	out := unsafe.Slice((*byte)(unsafe.Pointer(buf)), int(buflen))
	if len(s)+1 > len(out) {
		out[0] = 0
		return finish(withCode(codeErrRange, errors.New("output buffer too small")))
	}
	n := copy(out, s)
	out[n] = 0
	return C.int(codeOK)
}

func goString(s *C.char) string {
	if s == nil {
		return ""
	}
	return C.GoString(s)
}

var errNilArgument = withCode(codeErrInvalid, errors.New("nil argument"))

//export orbitnet_errmsg
func orbitnet_errmsg(buf *C.char, buflen C.size_t) C.int {
	lastErrors.mu.Lock()
	msg := lastErrors.m[threadKey()]
	lastErrors.mu.Unlock()
	if buf == nil || buflen == 0 {
		return C.int(codeErrRange)
	}
	out := unsafe.Slice((*byte)(unsafe.Pointer(buf)), int(buflen))
	n := copy(out[:len(out)-1], msg)
	out[n] = 0
	return C.int(codeOK)
}

//export orbitnet_identity
func orbitnet_identity(dir *C.char, deviceIDOut *C.char, outlen C.size_t) C.int {
	if dir == nil {
		return finish(errNilArgument)
	}
	id, err := apiIdentity(goString(dir))
	if err != nil {
		return finish(err)
	}
	setLastError(nil)
	return putCString(deviceIDOut, outlen, id)
}

//export orbitnet_dial
func orbitnet_dial(dir *C.char, addressURL *C.char, expectedDeviceID *C.char, tsHandle C.int, fdOut *C.int) C.int {
	if dir == nil || addressURL == nil || expectedDeviceID == nil || fdOut == nil {
		return finish(errNilArgument)
	}
	fd, err := apiDial(goString(dir), goString(addressURL), goString(expectedDeviceID), int(tsHandle))
	if err != nil {
		return finish(err)
	}
	*fdOut = C.int(fd)
	return finish(nil)
}

//export orbitnet_lookup
func orbitnet_lookup(deviceIDText *C.char, jsonOut *C.char, outlen C.size_t, retryAfterOut *C.int) C.int {
	if deviceIDText == nil || jsonOut == nil {
		return finish(errNilArgument)
	}
	body, retryAfter, err := apiLookup(goString(deviceIDText))
	if retryAfterOut != nil {
		*retryAfterOut = C.int(retryAfter)
	}
	if err != nil {
		return finish(err)
	}
	setLastError(nil)
	return putCString(jsonOut, outlen, body)
}

//export orbitnet_announce
func orbitnet_announce(dir *C.char, addressesJSON *C.char, reannounceSecondsOut *C.int) C.int {
	if dir == nil || addressesJSON == nil || reannounceSecondsOut == nil {
		return finish(errNilArgument)
	}
	seconds, err := apiAnnounce(goString(dir), goString(addressesJSON))
	*reannounceSecondsOut = C.int(seconds)
	return finish(err)
}

//export orbitnet_listen
func orbitnet_listen(dir *C.char, bindAddress *C.char, tsHandle C.int, listenerOut *C.int) C.int {
	if dir == nil || bindAddress == nil || listenerOut == nil {
		return finish(errNilArgument)
	}
	id, err := apiListen(goString(dir), goString(bindAddress), int(tsHandle))
	if err != nil {
		return finish(err)
	}
	*listenerOut = C.int(id)
	return finish(nil)
}

//export orbitnet_relay_join
func orbitnet_relay_join(dir *C.char, relayURL *C.char, listenerOut *C.int) C.int {
	if dir == nil || relayURL == nil || listenerOut == nil {
		return finish(errNilArgument)
	}
	id, err := apiRelayJoin(goString(dir), goString(relayURL))
	if err != nil {
		return finish(err)
	}
	*listenerOut = C.int(id)
	return finish(nil)
}

//export orbitnet_relay_pick
func orbitnet_relay_pick(urlOut *C.char, outlen C.size_t) C.int {
	picked, err := apiRelayPick()
	if err != nil {
		return finish(err)
	}
	setLastError(nil)
	return putCString(urlOut, outlen, picked)
}

//export orbitnet_accept
func orbitnet_accept(listener C.int, fdOut *C.int, peerDeviceIDOut *C.char, outlen C.size_t, remoteOut *C.char, remotelen C.size_t) C.int {
	if fdOut == nil || peerDeviceIDOut == nil {
		return finish(errNilArgument)
	}
	result, err := apiAccept(int(listener))
	if err != nil {
		return finish(err)
	}
	if code := putCString(peerDeviceIDOut, outlen, result.peer); code != 0 {
		closeFD(result.fd)
		return code
	}
	if remoteOut != nil && remotelen > 0 {
		if code := putCString(remoteOut, remotelen, result.remote); code != 0 {
			putCString(remoteOut, remotelen, "")
		}
	}
	*fdOut = C.int(result.fd)
	return finish(nil)
}

//export orbitnet_listener_addresses
func orbitnet_listener_addresses(listener C.int, jsonOut *C.char, outlen C.size_t) C.int {
	addresses, err := apiListenerAddresses(int(listener))
	if err != nil {
		return finish(err)
	}
	setLastError(nil)
	return putCString(jsonOut, outlen, addresses)
}

//export orbitnet_close_listener
func orbitnet_close_listener(listener C.int) C.int {
	return finish(apiCloseListener(int(listener)))
}
