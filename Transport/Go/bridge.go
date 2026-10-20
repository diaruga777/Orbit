package main

import (
	"io"
	"net"
	"os"
	"sync"
	"syscall"
	"time"
)

// bridgeToSocketpair copies both directions between conn and one end of a
// new AF_UNIX socketpair and returns the other end for the C caller.
//
// Either side ending tears the whole bridge down: the peer closing conn
// makes the caller read EOF (pending bytes are still delivered), and the
// caller closing its descriptor closes conn. Both copy goroutines exit
// within the teardown, so a closed bridge leaks nothing.
func bridgeToSocketpair(conn net.Conn) (int, error) {
	fds, err := syscall.Socketpair(syscall.AF_UNIX, syscall.SOCK_STREAM, 0)
	if err != nil {
		return -1, err
	}
	syscall.CloseOnExec(fds[0])
	syscall.CloseOnExec(fds[1])
	// Non-blocking before os.NewFile so the file supports deadlines; a
	// deadline is how the teardown unblocks the goroutine reading it.
	if err := syscall.SetNonblock(fds[1], true); err != nil {
		syscall.Close(fds[0])
		syscall.Close(fds[1])
		return -1, err
	}
	local := os.NewFile(uintptr(fds[1]), "orbitnet-bridge")

	var wg sync.WaitGroup
	teardown := sync.OnceFunc(func() {
		conn.Close()
		local.SetDeadline(time.Now())
	})
	wg.Add(2)
	go func() {
		defer wg.Done()
		var buf [1 << 16]byte
		io.CopyBuffer(local, conn, buf[:])
		shutdownWrite(local)
		teardown()
	}()
	go func() {
		defer wg.Done()
		var buf [1 << 16]byte
		io.CopyBuffer(conn, local, buf[:])
		teardown()
	}()
	go func() {
		wg.Wait()
		local.Close()
	}()
	return fds[0], nil
}

// shutdownWrite signals EOF to the caller's end without dropping bytes the
// caller has not read yet.
func shutdownWrite(f *os.File) {
	raw, err := f.SyscallConn()
	if err != nil {
		return
	}
	raw.Control(func(fd uintptr) {
		syscall.Shutdown(int(fd), syscall.SHUT_WR)
	})
}
