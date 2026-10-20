package appleadapter

import (
	"bytes"
	"context"
	"encoding/binary"
	"encoding/json"
	"errors"
	"io"
	"net"
	"time"
)

// BrokerDialer opens only an owner-controlled Mac Unix socket. LCA1 is local
// helper IPC, never the iPhone wire protocol. The Mac broker must authorize this
// single-use job token and issue phone endpoint grants only for StartService
// results from this pinned helper. It then supplies the opaque stream bytes.
func BrokerDialer(path, token string) Dial {
	return func(ctx context.Context, service Service, port uint16) (net.Conn, error) {
		if len(token) < 32 || len(token) > 128 || len(path) == 0 || len(path) > 100 || path[0] != '/' || port == 0 || (service != Lockdown && service != AFC && service != Installation) || (service == Lockdown && port != 62078) || (service != Lockdown && port == 62078) {
			return nil, errors.New("invalid Apple broker request")
		}
		socket, err := (&net.Dialer{}).DialContext(ctx, "unix", path)
		if err != nil {
			return nil, err
		}
		conn := newBoundConn(ctx, socket)
		deadline := time.Now().Add(45 * time.Second)
		if existing, ok := ctx.Deadline(); ok && existing.Before(deadline) {
			deadline = existing
		}
		conn.SetDeadline(deadline)
		data, err := json.Marshal(struct {
			Version        int     `json:"version"`
			Token          string  `json:"token"`
			Service        Service `json:"service"`
			Port           uint16  `json:"port"`
			FullCloseOnEOF bool    `json:"fullCloseOnEOF"`
		}{1, token, service, port, true})
		if err != nil {
			conn.Close()
			return nil, err
		}
		header := []byte{'L', 'C', 'A', '1', 0, 0, 0, 0}
		binary.BigEndian.PutUint32(header[4:], uint32(len(data)))
		if _, err = io.Copy(conn, io.MultiReader(bytes.NewReader(header), bytes.NewReader(data))); err != nil {
			conn.Close()
			return nil, err
		}
		ack := []byte{0}
		if _, err = io.ReadFull(conn, ack); err != nil {
			conn.Close()
			return nil, err
		}
		if ack[0] != 1 {
			conn.Close()
			return nil, Failure{"identity", "Apple broker rejected the device flow"}
		}
		deadline = time.Time{}
		if existing, ok := ctx.Deadline(); ok {
			deadline = existing
		}
		conn.SetDeadline(deadline)
		return conn, nil
	}
}
