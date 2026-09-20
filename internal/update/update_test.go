package update

import "testing"

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
