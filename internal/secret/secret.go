// Package secret generates the random credentials used by the node protocols.
package secret

import (
	"crypto/ecdh"
	"crypto/rand"
	"encoding/base64"
	"encoding/hex"
	"fmt"
	"io"
)

// passwordAlphabet keeps share-link passwords readable by every client we
// target: v2rayN, passwall, passwall2 and homeproxy. Staying alphanumeric means
// url.User never percent-encodes the userinfo, and homeproxy drops a userinfo
// that contains a `%`, which would otherwise leave the node without a password.
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

// UUID returns a random v4 UUID in canonical 8-4-4-4-12 form. Per-user
// credentials are generated locally so the panel never has to run the core
// binary once per account.
func UUID() string {
	var b [16]byte
	if _, err := rand.Read(b[:]); err != nil {
		return ""
	}
	b[6] = (b[6] & 0x0f) | 0x40
	b[8] = (b[8] & 0x3f) | 0x80
	return fmt.Sprintf("%x-%x-%x-%x-%x", b[0:4], b[4:6], b[6:8], b[8:10], b[10:16])
}

// tokenAlphabet omits the characters a human confuses when reading a
// subscription URL back from a screen: l, o, 0 and 1.
const tokenAlphabet = "abcdefghijkmnpqrstuvwxyz23456789"

// Token returns a 16 character subscription token (about 80 bits) built only
// from tokenAlphabet, so it stays ASCII and free of the regex metacharacters
// the stats user filter would otherwise have to escape.
func Token() string {
	const length = 16
	limit := 256 - 256%len(tokenAlphabet)
	out := make([]byte, length)
	buf := make([]byte, 1)
	for i := 0; i < length; {
		if _, err := io.ReadFull(rand.Reader, buf); err != nil {
			return ""
		}
		if int(buf[0]) >= limit {
			continue
		}
		out[i] = tokenAlphabet[int(buf[0])%len(tokenAlphabet)]
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

// RealityKeypair returns the X25519 keypair a VLESS Reality inbound needs: 32 random
// bytes as the private key and its base point multiple as the public key, both in
// base64 with the URL alphabet and no padding, which is the encoding sing-box's
// configuration uses. Generating it here rather than asking the core for it is the
// same reason UUID does its own work: the panel then needs no second program.
func RealityKeypair() (privateKey, publicKey string) {
	key, err := ecdh.X25519().GenerateKey(rand.Reader)
	if err != nil {
		return "", ""
	}
	privateKey = base64.RawURLEncoding.EncodeToString(key.Bytes())
	publicKey = base64.RawURLEncoding.EncodeToString(key.PublicKey().Bytes())
	return privateKey, publicKey
}
