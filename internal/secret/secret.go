// Package secret generates the random credentials used by the node protocols.
package secret

import (
	"crypto/rand"
	"encoding/hex"
	"io"
)

// passwordAlphabet is the intersection accepted by every share-link parser we
// target: v2rayN, passwall, passwall2, homeproxy and luci-app-ssr-plus. The
// last one parses hysteria2 userinfo with the bundled neturl, whose character
// class is only [A-Za-z0-9+.]; anything else (including the '-' and '_' of
// URL-safe base64) makes it drop the password, so the node shows up empty.
const passwordAlphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789"

// Password returns a 22 character alphanumeric password (about 131 bits of
// entropy) built only from passwordAlphabet.
func Password() string {
	const length = 22
	const limit = byte(256 - 256%len(passwordAlphabet))
	out := make([]byte, length)
	buf := make([]byte, 1)
	for i := 0; i < length; {
		if _, err := io.ReadFull(rand.Reader, buf); err != nil {
			return ""
		}
		if buf[0] >= limit {
			continue
		}
		out[i] = passwordAlphabet[int(buf[0])%len(passwordAlphabet)]
		i++
	}
	return string(out)
}

// ShortID returns an 8 character hex Reality short id.
func ShortID() string {
	b := make([]byte, 4)
	if _, err := io.ReadFull(rand.Reader, b); err != nil {
		return ""
	}
	return hex.EncodeToString(b)
}
