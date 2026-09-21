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
	// The password must survive a share link unescaped, so it may only use the
	// URL-safe alphabet.
	for _, r := range p {
		if !strings.ContainsRune("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_", r) {
			t.Fatalf("password %q contains a non URL-safe character", p)
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
