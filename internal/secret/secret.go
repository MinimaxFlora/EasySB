// Package secret generates the random credentials used by the node protocols.
package secret

import (
	"crypto/rand"
	"encoding/base64"
	"encoding/hex"
	"io"
)

// Password returns a URL-safe base64 encoded 16 byte random password (22
// chars). The alphabet is [A-Za-z0-9_-] with no padding so the value needs no
// percent-encoding inside a share link; some clients (for example OpenWrt's
// homeproxy) reject userinfo that contains escaped characters and would drop
// the password from the node.
func Password() string {
	b := make([]byte, 16)
	if _, err := io.ReadFull(rand.Reader, b); err != nil {
		return ""
	}
	return base64.RawURLEncoding.EncodeToString(b)
}

// ShortID returns an 8 character hex Reality short id.
func ShortID() string {
	b := make([]byte, 4)
	if _, err := io.ReadFull(rand.Reader, b); err != nil {
		return ""
	}
	return hex.EncodeToString(b)
}
