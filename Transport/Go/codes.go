package main

import (
	"context"
	"errors"
	"net"
	"os"
	"strings"
	"syscall"
)

// resultCode is the C return value. orbitnet.h mirrors this list.
type resultCode int32

const (
	codeOK               resultCode = 0
	codeErrInternal      resultCode = -1
	codeErrInvalid       resultCode = -2
	codeErrIdentity      resultCode = -3
	codeErrUnreachable   resultCode = -4
	codeErrHandshake     resultCode = -5
	codeErrMismatch      resultCode = -6
	codeErrRelay         resultCode = -7
	codeErrListenerGone  resultCode = -10
	codeErrBadHandle     resultCode = -11
	codeErrRange         resultCode = -12
	codeErrHTTPBase      resultCode = -1000 // an HTTP status s returns -(1000+s)
	codeErrHTTPStatusMax            = 999
)

// codedError carries a fixed code for failures with no typed marker of
// their own (a bad argument, an unknown handle).
type codedError struct {
	code resultCode
	err  error
}

func (e *codedError) Error() string { return e.err.Error() }
func (e *codedError) Unwrap() error { return e.err }

func withCode(code resultCode, err error) error {
	return &codedError{code: code, err: err}
}

func errorCode(err error) resultCode {
	var coded *codedError
	var mismatch *identityMismatchError
	var status *httpStatusError
	var relayErr *relayError
	switch {
	case err == nil:
		return codeOK
	case errors.As(err, &coded):
		return coded.code
	case errors.As(err, &mismatch):
		return codeErrMismatch
	case errors.As(err, &status):
		if status.status > 0 && status.status <= codeErrHTTPStatusMax {
			return codeErrHTTPBase - resultCode(status.status)
		}
		return codeErrInternal
	case errors.As(err, &relayErr):
		return codeErrRelay
	case errors.Is(err, errListenerClosed):
		return codeErrListenerGone
	default:
		return classifyMessage(err)
	}
}

// classifyMessage sorts an error without a typed marker into the coarse
// codes: a dial or timeout failure is unreachable, a TLS alert is a
// handshake failure, everything else internal.
func classifyMessage(err error) resultCode {
	var opErr *net.OpError
	if errors.As(err, &opErr) && opErr.Op == "dial" {
		return codeErrUnreachable
	}
	if errors.Is(err, context.DeadlineExceeded) || errors.Is(err, os.ErrDeadlineExceeded) ||
		errors.Is(err, syscall.ECONNREFUSED) || errors.Is(err, syscall.EHOSTUNREACH) ||
		errors.Is(err, syscall.ENETUNREACH) || errors.Is(err, syscall.ECONNRESET) {
		return codeErrUnreachable
	}
	var ne net.Error
	if errors.As(err, &ne) && ne.Timeout() {
		return codeErrUnreachable
	}
	msg := err.Error()
	switch {
	case strings.Contains(msg, "tls:"), strings.Contains(msg, "certificate"),
		strings.Contains(msg, "handshake"), strings.Contains(msg, "EOF"):
		return codeErrHandshake
	case strings.HasPrefix(msg, "tailnet"):
		return codeErrBadHandle
	case strings.HasPrefix(msg, "dial:"), strings.HasPrefix(msg, "relay:"),
		strings.HasPrefix(msg, "relay session:"), strings.HasPrefix(msg, "discovery:"),
		strings.HasPrefix(msg, "relay pool:"):
		return codeErrUnreachable
	}
	return codeErrInternal
}
