package core

import (
	"archive/tar"
	"bytes"
	"compress/gzip"
	"context"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

// TestFetchReleasesLive hits the real GitHub API. It is opt-in so the default
// test run stays offline: set EASYSB_LIVE=1 to enable it.
func TestFetchReleasesLive(t *testing.T) {
	if os.Getenv("EASYSB_LIVE") == "" {
		t.Skip("set EASYSB_LIVE=1 to query GitHub")
	}
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	rels, err := FetchReleases(ctx)
	if err != nil {
		t.Fatalf("FetchReleases: %v", err)
	}
	if rels.Stable.Version == "" {
		t.Fatalf("no stable release: %+v", rels)
	}
	t.Logf("arch=%s stable=%s url=%s alpha=%s", Arch(), rels.Stable.Version, rels.Stable.URL, rels.Alpha.Version)
}

// TestInstallLive downloads a real release archive and installs it into a temp
// directory, then runs it. Opt-in via EASYSB_LIVE=1.
func TestInstallLive(t *testing.T) {
	if os.Getenv("EASYSB_LIVE") == "" {
		t.Skip("set EASYSB_LIVE=1 to download a release")
	}
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Minute)
	defer cancel()
	rels, err := FetchReleases(ctx)
	if err != nil {
		t.Fatalf("FetchReleases: %v", err)
	}
	if rels.Stable.Version == "" {
		t.Skip("no stable release")
	}

	dir := t.TempDir()
	dest := filepath.Join(dir, "sing-box")
	tmp := filepath.Join(dir, "core.tgz")
	if err := Download(ctx, rels.Stable.URL, tmp); err != nil {
		t.Fatalf("Download: %v", err)
	}
	if err := ExtractBinary(tmp, dest); err != nil {
		t.Fatalf("ExtractBinary: %v", err)
	}
	out, err := run(ctx, dest, "version")
	if err != nil {
		t.Fatalf("version: %v (%s)", err, out)
	}
	if !strings.Contains(out, rels.Stable.Version) {
		t.Fatalf("version output %q missing %s", out, rels.Stable.Version)
	}
}

func TestArchFromUname(t *testing.T) {
	cases := map[string]string{
		"x86_64":  "amd64",
		"aarch64": "arm64",
		"armv7l":  "armv7",
		"i686":    "386",
		"riscv64": "riscv64",
		"weird":   "",
	}
	for in, want := range cases {
		if got := ArchFromUname(in); got != want {
			t.Errorf("ArchFromUname(%q) = %q, want %q", in, got, want)
		}
	}
}

func TestAssetURL(t *testing.T) {
	got := AssetURL("v1.10.0", "amd64")
	want := "https://github.com/SagerNet/sing-box/releases/download/v1.10.0/sing-box-1.10.0-linux-amd64.tar.gz"
	if got != want {
		t.Fatalf("AssetURL = %q, want %q", got, want)
	}
}

func TestSelectRelease(t *testing.T) {
	rels := []ghRelease{
		{Tag: "v1.11.0-alpha.3", Prerelease: true, Assets: []ghAsset{
			{Name: "sing-box-1.11.0-alpha.3-linux-amd64.tar.gz", URL: "https://example/alpha.tgz"},
		}},
		{Tag: "v1.10.0", Assets: []ghAsset{
			{Name: "sing-box-1.10.0-linux-arm64.tar.gz", URL: "https://example/other.tgz"},
			{Name: "sing-box-1.10.0-linux-amd64.tar.gz", URL: "https://example/stable.tgz"},
		}},
	}

	stable := selectRelease(rels, false, "amd64")
	if stable.Version != "1.10.0" || stable.URL != "https://example/stable.tgz" {
		t.Fatalf("stable = %+v", stable)
	}

	alpha := selectRelease(rels, true, "amd64")
	if alpha.Version != "1.11.0-alpha.3" || alpha.URL != "https://example/alpha.tgz" {
		t.Fatalf("alpha = %+v", alpha)
	}

	// Missing asset falls back to the conventional download URL.
	fallback := selectRelease(rels, false, "riscv64")
	if !strings.HasSuffix(fallback.URL, "sing-box-1.10.0-linux-riscv64.tar.gz") {
		t.Fatalf("fallback url = %q", fallback.URL)
	}
}

func TestExtractBinary(t *testing.T) {
	archive := filepath.Join(t.TempDir(), "core.tgz")
	if err := writeArchive(archive, "sing-box-1.10.0-linux-amd64/sing-box", "#!/bin/sh\n"); err != nil {
		t.Fatal(err)
	}

	dest := filepath.Join(t.TempDir(), "sing-box")
	if err := ExtractBinary(archive, dest); err != nil {
		t.Fatalf("ExtractBinary: %v", err)
	}
	data, err := os.ReadFile(dest)
	if err != nil {
		t.Fatal(err)
	}
	if string(data) != "#!/bin/sh\n" {
		t.Fatalf("binary content = %q", data)
	}
	info, _ := os.Stat(dest)
	if info.Mode().Perm()&0o111 == 0 {
		t.Fatalf("binary is not executable: %v", info.Mode())
	}
}

func TestExtractBinaryMissing(t *testing.T) {
	archive := filepath.Join(t.TempDir(), "core.tgz")
	if err := writeArchive(archive, "readme.txt", "hello"); err != nil {
		t.Fatal(err)
	}
	if err := ExtractBinary(archive, filepath.Join(t.TempDir(), "sing-box")); err == nil {
		t.Fatal("expected error when binary is absent")
	}
}

func TestRandomUUID(t *testing.T) {
	u := randomUUID()
	if len(u) != 36 {
		t.Fatalf("uuid = %q", u)
	}
	if u[14] != '4' {
		t.Fatalf("expected v4 uuid, got %q", u)
	}
}

func writeArchive(path, name, content string) error {
	f, err := os.Create(path)
	if err != nil {
		return err
	}
	defer f.Close()

	gz := gzip.NewWriter(f)
	defer gz.Close()
	tw := tar.NewWriter(gz)
	defer tw.Close()

	if err := tw.WriteHeader(&tar.Header{Name: name, Mode: 0o644, Size: int64(len(content))}); err != nil {
		return err
	}
	_, err = bytes.NewBufferString(content).WriteTo(tw)
	return err
}
