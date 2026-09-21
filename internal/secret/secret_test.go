package secret

import (
	"strings"
	"testing"
)

func TestPassword(t *testing.T) {
	p := Password()
	if len(p) != 22 {
		t.Fatalf("password length = %d, want 22", len(p))
	}
	// Passwords stay alphanumeric so url.User introduces no percent-encoding:
	// some share-link parsers drop a userinfo that contains a `%`.
	for _, r := range p {
		if !strings.ContainsRune("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789", r) {
			t.Fatalf("password %q contains a non-alphanumeric character", p)
		}
	}
	if Password() == p {
		t.Fatal("passwords should differ")
	}
}

func TestShortID(t *testing.T) {
	id := ShortID()
	if len(id) != 8 {
		t.Fatalf("short id length = %d, want 8", len(id))
	}
}
