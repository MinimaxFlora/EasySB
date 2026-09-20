// Package secret generates the random credentials used by the node protocols.
package secret

import (
	"crypto/rand"
	"encoding/base64"
	"encoding/hex"
	"io"
)

// Password returns a base64 encoded 16 byte random password (24 chars).
func Password() string {
	b := make([]byte, 16)
	if _, err := io.ReadFull(rand.Reader, b); err != nil {
		return ""
	}
	return base64.StdEncoding.EncodeToString(b)
}

// ShortID returns an 8 character hex Reality short id.
func ShortID() string {
	b := make([]byte, 4)
	if _, err := io.ReadFull(rand.Reader, b); err != nil {
		return ""
	}
	return hex.EncodeToString(b)
}
