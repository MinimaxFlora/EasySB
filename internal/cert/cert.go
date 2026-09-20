// Package cert resolves TLS certificates for the sing-box server: certificates
// issued by acme.sh when available, otherwise a self-signed placeholder.
package cert

import (
	"context"
	"errors"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"time"

	"github.com/MinimaxFlora/EasySB/internal/sysinfo"
)

// Resolved points at the certificate pair currently in use.
type Resolved struct {
	Fullchain  string
	Key        string
	SelfSigned bool
}

// ACMEDir returns the acme.sh home directory.
func ACMEDir() string {
	home, err := os.UserHomeDir()
	if err != nil || home == "" {
		home = "/root"
	}
	return filepath.Join(home, ".acme.sh")
}

// ACMESh returns the expected acme.sh script path.
func ACMESh() string {
	return filepath.Join(ACMEDir(), "acme.sh")
}

// Paths resolves the certificate pair for a domain issued by acme.sh.
func Paths(domain string) (string, string, bool) {
	if domain == "" {
		return "", "", false
	}
	ecc := filepath.Join(ACMEDir(), domain+"_ecc")
	if fullchain, key, ok := pair(ecc, domain); ok {
		return fullchain, key, true
	}
	plain := filepath.Join(ACMEDir(), domain)
	return pair(plain, domain)
}

func pair(dir, domain string) (string, string, bool) {
	fullchain := filepath.Join(dir, "fullchain.cer")
	key := filepath.Join(dir, domain+".key")
	if exists(fullchain) && exists(key) {
		return fullchain, key, true
	}
	return "", "", false
}

// Domains lists cert domains present in the acme.sh directory.
func Domains() []string {
	entries, err := os.ReadDir(ACMEDir())
	if err != nil {
		return nil
	}
	var out []string
	for _, e := range entries {
		if !e.IsDir() {
			continue
		}
		dir := filepath.Join(ACMEDir(), e.Name())
		if !exists(filepath.Join(dir, "fullchain.cer")) {
			continue
		}
		out = append(out, strings.TrimSuffix(e.Name(), "_ecc"))
	}
	return out
}

// ResolveActive returns the active certificate pair. It prefers an acme.sh
// certificate for the configured domain and otherwise makes sure a self-signed
// placeholder exists under /etc/sing-box/cert.
func ResolveActive(domain string) (Resolved, error) {
	if fullchain, key, ok := Paths(domain); ok {
		return Resolved{Fullchain: fullchain, Key: key}, nil
	}

	cn := domain
	if cn == "" {
		cn = "easysb.local"
	}
	if !exists(sysinfo.SelfSignedCert) || !exists(sysinfo.SelfSignedKey) {
		if err := GenerateSelfSigned(sysinfo.SelfSignedCert, sysinfo.SelfSignedKey, cn); err != nil {
			return Resolved{}, err
		}
	}
	return Resolved{
		Fullchain:  sysinfo.SelfSignedCert,
		Key:        sysinfo.SelfSignedKey,
		SelfSigned: true,
	}, nil
}

// GenerateSelfSigned creates a self-signed EC certificate using openssl.
func GenerateSelfSigned(certPath, keyPath, cn string) error {
	if _, err := exec.LookPath("openssl"); err != nil {
		return errors.New("openssl not found")
	}
	if err := os.MkdirAll(filepath.Dir(certPath), 0o755); err != nil {
		return err
	}

	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()

	if err := runOpenSSL(ctx, "ecparam", "-genkey", "-name", "prime256v1", "-out", keyPath); err != nil {
		return err
	}
	return runOpenSSL(ctx, "req", "-new", "-x509", "-days", "3650",
		"-key", keyPath, "-out", certPath, "-subj", "/CN="+cn)
}

func runOpenSSL(ctx context.Context, args ...string) error {
	cmd := exec.CommandContext(ctx, "openssl", args...)
	cmd.Env = append(os.Environ(), "LC_ALL=C")
	out, err := cmd.CombinedOutput()
	if err != nil {
		msg := strings.TrimSpace(string(out))
		if msg == "" {
			msg = err.Error()
		}
		return errors.New("openssl " + args[0] + ": " + msg)
	}
	return nil
}

func exists(path string) bool {
	info, err := os.Stat(path)
	return err == nil && info.Size() > 0
}
