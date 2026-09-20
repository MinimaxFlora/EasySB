package update

import (
	"strings"
	"testing"
)

func TestAssetName(t *testing.T) {
	cases := map[string]string{
		"amd64": "amd64", "arm64": "arm64", "arm": "armv7",
		"386": "386", "riscv64": "riscv64", "s390x": "s390x",
	}
	for in, want := range cases {
		got, ok := AssetName(in)
		if !ok || got != want {
			t.Fatalf("AssetName(%q) = %q,%v want %q", in, got, ok, want)
		}
	}
	if _, ok := AssetName("mips"); ok {
		t.Fatal("expected unsupported architecture to be rejected")
	}
}

func TestReleaseTag(t *testing.T) {
	cases := map[string]string{
		"3.0.0":   "v3.0.0",
		"v3.0.0":  "v3.0.0",
		" 3.0.0 ": "v3.0.0",
	}
	for in, want := range cases {
		if got := ReleaseTag(in); got != want {
			t.Fatalf("ReleaseTag(%q) = %q, want %q", in, got, want)
		}
	}
}

func TestAssetURLUsesVersionTag(t *testing.T) {
	got, err := AssetURL("3.0.0")
	if err != nil {
		t.Fatalf("AssetURL(3.0.0) error: %v", err)
	}
	if !strings.Contains(got, "/releases/download/v3.0.0/easysb-linux-") {
		t.Fatalf("AssetURL(3.0.0) = %q, want a v3.0.0 download path", got)
	}
}
