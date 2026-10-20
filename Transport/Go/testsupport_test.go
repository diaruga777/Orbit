package main

import "crypto/tls"

func tlsConfigRequestingClientCert() tls.Config {
	return tls.Config{ClientAuth: tls.RequestClientCert}
}
