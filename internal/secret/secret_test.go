package secret

import "testing"

func TestPassword(t *testing.T) {
	p := Password()
	if len(p) != 24 {
		t.Fatalf("password length = %d, want 24", len(p))
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
