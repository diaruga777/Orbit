
package main

import (
	"context"
	"errors"
	"net"
)

// tailnetServer is the part of *tsnet.Server the BEP layer uses.
type tailnetServer interface {
	Dial(ctx context.Context, network, address string) (net.Conn, error)
	Listen(network, address string) (net.Listener, error)
}

// The standalone module has no tsnet; every tailnet handle is unknown.
func lookupTailnetServer(handle int) (tailnetServer, error) {
	return nil, errors.New("tailnet: not linked in the standalone build")
}
