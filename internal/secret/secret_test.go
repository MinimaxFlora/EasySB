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
	// Several share-link parsers only accept alphanumeric userinfo (for example
	// luci-app-ssr-plus via neturl), so the password may not use any other
	// character even if URL-safe.
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
