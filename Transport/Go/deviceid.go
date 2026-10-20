package main

import (
	"crypto/sha256"
	"encoding/base32"
	"errors"
	"fmt"
	"strings"
)

// deviceID is the SHA-256 of a peer's DER certificate
// (claudedocs/vault-bep-reference.md §D).
type deviceID [32]byte

const base32Alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZ234567"

var base32NoPad = base32.StdEncoding.WithPadding(base32.NoPadding)

func deviceIDFromCertDER(der []byte) deviceID {
	return deviceID(sha256.Sum256(der))
}

// String returns the checked, dashed 63-character form Syncthing prints.
func (d deviceID) String() string {
	raw := base32NoPad.EncodeToString(d[:]) // 52 characters
	var checked strings.Builder
	for group := 0; group < 4; group++ {
		part := raw[group*13 : group*13+13]
		checked.WriteString(part)
		check, _ := luhn32(part)
		checked.WriteByte(check)
	}
	s := checked.String()
	var out strings.Builder
	for i := 0; i < len(s); i++ {
		if i > 0 && i%7 == 0 {
			out.WriteByte('-')
		}
		out.WriteByte(s[i])
	}
	return out.String()
}

// parseDeviceID accepts the 56-character checked form and the 52-character
// unchecked form, with or without dashes and spaces, and repairs the
// 0→O, 1→I, 8→B typos Syncthing repairs.
func parseDeviceID(input string) (deviceID, error) {
	var id deviceID
	var cleaned strings.Builder
	for _, r := range strings.ToUpper(input) {
		switch r {
		case '-', ' ', '=':
			continue
		case '0':
			cleaned.WriteByte('O')
		case '1':
			cleaned.WriteByte('I')
		case '8':
			cleaned.WriteByte('B')
		default:
			if r > 0x7F {
				return id, fmt.Errorf("device ID: invalid character %q", r)
			}
			cleaned.WriteByte(byte(r))
		}
	}
	s := cleaned.String()
	var unchecked string
	switch len(s) {
	case 56:
		var b strings.Builder
		for group := 0; group < 4; group++ {
			part := s[group*14 : group*14+14]
			check, err := luhn32(part[:13])
			if err != nil {
				return id, err
			}
			if check != part[13] {
				return id, fmt.Errorf("device ID: check character mismatch in group %d", group)
			}
			b.WriteString(part[:13])
		}
		unchecked = b.String()
	case 52:
		unchecked = s
	default:
		return id, fmt.Errorf("device ID: wrong length %d", len(s))
	}
	decoded, err := base32NoPad.DecodeString(unchecked)
	if err != nil {
		return id, fmt.Errorf("device ID: %w", err)
	}
	if len(decoded) != 32 {
		return id, fmt.Errorf("device ID: decoded to %d bytes", len(decoded))
	}
	copy(id[:], decoded)
	return id, nil
}

// luhn32 is Syncthing's check character: the factor alternates 1, 2, 1, 2
// starting at 1, and each addend folds as a/32 + a%32.
func luhn32(s string) (byte, error) {
	factor := 1
	sum := 0
	const n = 32
	for i := 0; i < len(s); i++ {
		codepoint := strings.IndexByte(base32Alphabet, s[i])
		if codepoint < 0 {
			return 0, fmt.Errorf("device ID: invalid character %q", s[i])
		}
		addend := factor * codepoint
		if factor == 2 {
			factor = 1
		} else {
			factor = 2
		}
		addend = addend/n + addend%n
		sum += addend
	}
	remainder := sum % n
	return base32Alphabet[(n-remainder)%n], nil
}

var errNoDeviceID = errors.New("device ID: empty")
