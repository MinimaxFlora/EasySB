package cert

import (
	"os"
	"os/exec"
	"path/filepath"
	"testing"
)

func TestPathsAndDomains(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)

	dir := filepath.Join(home, ".acme.sh", "example.com_ecc")
	if err := os.MkdirAll(dir, 0o755); err != nil {
		t.Fatal(err)
	}
	for _, name := range []string{"fullchain.cer", "example.com.key"} {
		if err := os.WriteFile(filepath.Join(dir, name), []byte("x"), 0o600); err != nil {
			t.Fatal(err)
		}
	}

	fullchain, key, ok := Paths("example.com")
	if !ok {
		t.Fatal("expected cert paths for example.com")
	}
	if filepath.Base(fullchain) != "fullchain.cer" || filepath.Base(key) != "example.com.key" {
		t.Fatalf("unexpected paths: %s %s", fullchain, key)
	}

	if _, _, ok := Paths("missing.com"); ok {
		t.Fatal("unexpected cert for missing.com")
	}

	domains := Domains()
	if len(domains) != 1 || domains[0] != "example.com" {
		t.Fatalf("domains = %v", domains)
	}
}

func TestACMEInstalled(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	if ACMEInstalled() {
		t.Fatal("expected acme.sh to be missing")
	}
	dir := filepath.Join(home, ".acme.sh")
	if err := os.MkdirAll(dir, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(dir, "acme.sh"), []byte("#!/bin/sh\n"), 0o755); err != nil {
		t.Fatal(err)
	}
	if !ACMEInstalled() {
		t.Fatal("expected acme.sh to be detected")
	}
}

func TestGenerateSelfSigned(t *testing.T) {
	if _, err := exec.LookPath("openssl"); err != nil {
		t.Skip("openssl not available")
	}
	dir := t.TempDir()
	certPath := filepath.Join(dir, "fullchain.cer")
	keyPath := filepath.Join(dir, "private.key")

	if err := GenerateSelfSigned(certPath, keyPath, "easysb.local"); err != nil {
		t.Fatalf("GenerateSelfSigned: %v", err)
	}
	for _, p := range []string{certPath, keyPath} {
		info, err := os.Stat(p)
		if err != nil {
			t.Fatalf("missing %s: %v", p, err)
		}
		if info.Size() == 0 {
			t.Fatalf("empty file %s", p)
		}
	}
}
