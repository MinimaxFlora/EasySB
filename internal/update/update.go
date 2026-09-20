// Package update self-updates the EasySB binary from the v<version> GitHub
// release, mirroring the legacy script's self-update flow.
package update

import (
	"context"
	"crypto/sha256"
	"errors"
	"io"
	"os"
	"runtime"
	"strings"

	"github.com/MinimaxFlora/EasySB/internal/core"
)

// Repo is the EasySB repository that publishes the binaries.
const Repo = "MinimaxFlora/EasySB"

// ReleaseTag maps an EasySB version to its GitHub release tag.
func ReleaseTag(version string) string {
	return "v" + strings.TrimPrefix(strings.TrimSpace(version), "v")
}

// versionURL points at the raw VERSION file on the default branch.
const versionURL = "https://raw.githubusercontent.com/" + Repo + "/master/VERSION"

// AssetName maps a Go architecture to the published asset suffix.
func AssetName(goarch string) (string, bool) {
	switch goarch {
	case "amd64":
		return "amd64", true
	case "arm64":
		return "arm64", true
	case "arm":
		return "armv7", true
	case "386":
		return "386", true
	case "riscv64":
		return "riscv64", true
	case "s390x":
		return "s390x", true
	}
	return "", false
}

// AssetURL returns the download URL for an EasySB version and the current
// architecture.
func AssetURL(version string) (string, error) {
	asset, ok := AssetName(runtime.GOARCH)
	if !ok {
		return "", errors.New("unsupported architecture: " + runtime.GOARCH)
	}
	return "https://github.com/" + Repo + "/releases/download/" + ReleaseTag(version) + "/easysb-linux-" + asset, nil
}

// RemoteVersion downloads the published VERSION file.
func RemoteVersion(ctx context.Context) (string, error) {
	tmp, err := os.CreateTemp("", "easysb-version-*")
	if err != nil {
		return "", err
	}
	path := tmp.Name()
	tmp.Close()
	defer os.Remove(path)

	if err := core.Download(ctx, versionURL, path); err != nil {
		return "", err
	}
	data, err := os.ReadFile(path)
	if err != nil {
		return "", err
	}
	return strings.TrimSpace(string(data)), nil
}

// Apply downloads the current architecture binary and replaces the running
// executable. It returns false when the installed binary already matches the
// remote build. current is the running EasySB version string.
func Apply(ctx context.Context, current string, log func(string)) (bool, string, error) {
	remote, err := RemoteVersion(ctx)
	if err != nil {
		log("cannot read remote version: " + err.Error())
	}
	if remote != "" {
		log("remote version: " + remote)
		if current != "" && remote == current {
			return false, remote, nil
		}
	}

	target := remote
	if target == "" {
		target = current
	}
	if target == "" {
		return false, remote, errors.New("missing version for release tag")
	}
	url, err := AssetURL(target)
	if err != nil {
		return false, remote, err
	}
	exe, err := os.Executable()
	if err != nil {
		return false, remote, err
	}
	tmp := exe + ".new"

	log("GET " + url)
	if err := core.Download(ctx, url, tmp); err != nil {
		return false, remote, err
	}
	if err := os.Chmod(tmp, 0o755); err != nil {
		return false, remote, err
	}
	if same, err := sameFile(exe, tmp); err == nil && same {
		os.Remove(tmp)
		return false, remote, nil
	}
	if err := os.Rename(tmp, exe); err != nil {
		os.Remove(tmp)
		return false, remote, err
	}
	return true, remote, nil
}

func sameFile(a, b string) (bool, error) {
	ha, err := hashFile(a)
	if err != nil {
		return false, err
	}
	hb, err := hashFile(b)
	if err != nil {
		return false, err
	}
	return ha == hb, nil
}

func hashFile(path string) ([32]byte, error) {
	f, err := os.Open(path)
	if err != nil {
		return [32]byte{}, err
	}
	defer f.Close()
	h := sha256.New()
	if _, err := io.Copy(h, f); err != nil {
		return [32]byte{}, err
	}
	var out [32]byte
	copy(out[:], h.Sum(nil))
	return out, nil
}
