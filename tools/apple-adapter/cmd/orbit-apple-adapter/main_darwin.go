// This helper is Mac-only. The phone carries opaque Apple bytes, never host keys.
package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"os/signal"
	"path/filepath"
	"syscall"

	adapter "orbit/apple-adapter"
)

type request struct {
	Artifact adapter.Artifact `json:"artifact"`
	Broker   string           `json:"broker"`
	Token    string           `json:"token"`
}
type reply struct {
	Kind              string `json:"kind,omitempty"`
	DefinitiveFailure bool   `json:"definitiveFailure"`
	Confirmed         bool   `json:"confirmed"`
	HandedOff         bool   `json:"handedOff"`
	Stage             string `json:"stage"`
	Error             string `json:"error,omitempty"`
}

func main() {
	result := run()
	if err := json.NewEncoder(os.Stdout).Encode(result); err != nil {
		os.Exit(2)
	}
	if !result.Confirmed {
		os.Exit(1)
	}
}
func run() reply {
	result := reply{Stage: "preflight"}
	if len(os.Args) != 2 {
		result.Error = "expected one private request file"
		return result
	}
	req, err := load(os.Args[1])
	if err != nil {
		result.Error = err.Error()
		return result
	}
	ctx, cancel := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer cancel()
	pair, err := adapter.ReadMacPairRecord(ctx, req.Artifact.DeviceID)
	if err != nil {
		result.Stage = "pairing"
		result.Kind = "pairing"
		result.Error = "The existing Apple host pairing record is unavailable."
		return result
	}
	outcome := (adapter.Adapter{Pair: pair, Dial: adapter.BrokerDialer(req.Broker, req.Token)}).Install(ctx, req.Artifact)
	result.Kind = outcome.Kind
	result.DefinitiveFailure = outcome.DefinitiveFailure
	result.Confirmed = outcome.Confirmed
	result.HandedOff = outcome.HandedOff
	result.Stage = outcome.Stage
	if outcome.Err != nil {
		result.Error = outcome.Err.Error()
	}
	return result
}
func load(path string) (request, error) {
	var value request
	info, err := os.Lstat(path)
	if err != nil {
		return value, errors.New("private request file unavailable")
	}
	owner, ok := info.Sys().(*syscall.Stat_t)
	if !ok || owner.Uid != uint32(os.Getuid()) || info.Mode().Perm()&0077 != 0 || !info.Mode().IsRegular() || info.Size() > 4096 {
		return value, errors.New("request file must be small and owner-only")
	}
	f, err := os.Open(path)
	if err != nil {
		return value, err
	}
	defer f.Close()
	opened, err := f.Stat()
	if err != nil || !os.SameFile(info, opened) {
		return value, errors.New("private request file changed")
	}
	decoder := json.NewDecoder(io.LimitReader(f, 4097))
	decoder.DisallowUnknownFields()
	if err = decoder.Decode(&value); err != nil {
		return value, errors.New("invalid Apple adapter request")
	}
	var trailing any
	if decoder.Decode(&trailing) != io.EOF {
		return value, errors.New("trailing Apple adapter request data")
	}
	if !filepath.IsAbs(value.Artifact.Package) || !filepath.IsAbs(value.Broker) || len(value.Token) < 32 {
		return value, errors.New("invalid private adapter paths or token")
	}
	parent, err := os.Stat(filepath.Dir(value.Broker))
	if err != nil {
		return value, errors.New("private broker directory unavailable")
	}
	parentOwner, ok := parent.Sys().(*syscall.Stat_t)
	if !ok || parentOwner.Uid != uint32(os.Getuid()) || parent.Mode().Perm()&0077 != 0 || !parent.IsDir() {
		return value, fmt.Errorf("broker directory must be owner-only")
	}
	return value, nil
}
