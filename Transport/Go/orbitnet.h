// orbitnet: authenticated plaintext BEP sockets over TLS 1.3 to Syncthing
// peers, compiled into the libtailscale archive (Orbit).
//
// Every function returns 0 on success or a negative LUNABEP_ERR_* code. The
// message for the last failure on the CALLING THREAD is readable with
// orbitnet_errmsg. Blocking calls may run from any thread.
//
// Connections come back as one end of an AF_UNIX socketpair carrying the
// plaintext BEP byte stream: read(2), write(2), shutdown(2), close(2).
// Closing the descriptor closes the TLS connection; the peer closing makes
// read(2) return 0 after the pending bytes.

#include <stddef.h>

#ifndef LUNABEP_H
#define LUNABEP_H

#ifdef __cplusplus
extern "C" {
#endif

enum {
	LUNABEP_OK = 0,
	LUNABEP_ERR_INTERNAL = -1,
	LUNABEP_ERR_INVALID = -2,        // bad argument (URL, device ID, bind address)
	LUNABEP_ERR_IDENTITY = -3,       // cert.pem/key.pem could not be loaded or created
	LUNABEP_ERR_UNREACHABLE = -4,    // TCP dial, timeout, or HTTP transport failure
	LUNABEP_ERR_HANDSHAKE = -5,      // TLS handshake failed
	LUNABEP_ERR_MISMATCH = -6,       // peer certificate hash != expected device ID
	LUNABEP_ERR_RELAY = -7,          // relay refused (not found, full, wrong token)
	LUNABEP_ERR_LISTENER_GONE = -10, // orbitnet_accept woken by orbitnet_close_listener
	LUNABEP_ERR_BAD_HANDLE = -11,    // unknown listener or tailnet handle
	LUNABEP_ERR_RANGE = -12,         // output buffer too small
	// An HTTP status s from a discovery server returns -(LUNABEP_ERR_HTTP_BASE + s).
	LUNABEP_ERR_HTTP_BASE = 1000,
};

// Copies the calling thread's last error message (NUL-terminated).
extern int orbitnet_errmsg(char* buf, size_t buflen);

// Loads dir/cert.pem + dir/key.pem or creates them (ECDSA P-256, CN=syncthing,
// 20 years; files 0600, dir 0700). Writes the canonical device ID (63 chars).
extern int orbitnet_identity(const char* dir, char* device_id_out, size_t outlen);

// Dials `tcp://host:port` (plain, or through the tsnet server `ts_handle`
// when non-zero) or `relay://host:port/?id=…`, completes the BEP TLS 1.3
// handshake, verifies the peer is `expected_device_id`, and returns the
// plaintext socketpair descriptor.
extern int orbitnet_dial(const char* dir, const char* address_url,
                        const char* expected_device_id, int ts_handle, int* fd_out);

// Global discovery lookup. On 200 copies the server's JSON
// (`{"seen":…,"addresses":[…]}`). On another status returns
// -(LUNABEP_ERR_HTTP_BASE + status) and writes the Retry-After seconds.
extern int orbitnet_lookup(const char* device_id, char* json_out, size_t outlen,
                          int* retry_after_out);

// Global discovery announce with the device certificate. `addresses_json` is
// `{"addresses":[…]}`. On 204 writes the Reannounce-After seconds; on another
// status returns -(LUNABEP_ERR_HTTP_BASE + status) and writes Retry-After.
extern int orbitnet_announce(const char* dir, const char* addresses_json,
                            int* reannounce_seconds_out);

// TLS server listener on `bind_address` ("0.0.0.0:22000", ":0", …), on the
// tsnet server when `ts_handle` is non-zero.
extern int orbitnet_listen(const char* dir, const char* bind_address, int ts_handle,
                          int* listener_out);

// Joins a relay in permanent protocol mode; invitations become accepted
// connections of the returned listener. Reconnects with backoff until closed.
extern int orbitnet_relay_join(const char* dir, const char* relay_url, int* listener_out);

// Picks the lowest-latency public relay; writes `relay://host:port/?id=…`.
extern int orbitnet_relay_pick(char* url_out, size_t outlen);

// Blocks for the next authenticated connection on `listener`. Writes the
// socketpair descriptor, the peer's canonical device ID, and a remote
// description (`tcp:1.2.3.4:5` or `relay:host`). Returns
// LUNABEP_ERR_LISTENER_GONE once the listener is closed.
extern int orbitnet_accept(int listener, int* fd_out, char* peer_device_id_out,
                          size_t outlen, char* remote_out, size_t remotelen);

// Writes a JSON array of Syncthing address URLs to announce for `listener`.
extern int orbitnet_listener_addresses(int listener, char* json_out, size_t outlen);

// Stops accepting and wakes blocked orbitnet_accept callers.
extern int orbitnet_close_listener(int listener);

#ifdef __cplusplus
}
#endif

#endif /* LUNABEP_H */
