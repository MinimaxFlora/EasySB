// Package cert resolves TLS certificates for the sing-box server: certificates
// issued by acme.sh when available, otherwise a self-signed placeholder.
package cert

import (
	"context"
	"errors"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
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
//
// $HOME is not a reliable answer here: the panel runs as root from the install
// script, from sudo and from systemd units, each of which can hand it a different
// HOME, while acme.sh always installs into the invoking user's home. So the
// candidates are probed for an actual acme.sh installation instead of trusted, and
// the ones that exist win over the ones that merely should.
func ACMEDir() string {
	if dir := strings.TrimSpace(os.Getenv(ACMEHomeEnv)); dir != "" {
		return dir
	}
	primary := filepath.Join(homeDir(), ".acme.sh")
	for _, dir := range []string{primary, "/root/.acme.sh"} {
		if looksLikeACMEHome(dir) {
			return dir
		}
	}
	return primary
}

// homeDir is $HOME with a root fallback for the environments that do not set it.
func homeDir() string {
	if home, err := os.UserHomeDir(); err == nil && home != "" {
		return home
	}
	return "/root"
}

// looksLikeACMEHome reports whether a directory holds an acme.sh installation or
// certificates issued by one.
func looksLikeACMEHome(dir string) bool {
	if exists(filepath.Join(dir, "acme.sh")) {
		return true
	}
	return len(certDirs(dir)) > 0
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

// Usable reports whether a real, publicly trusted certificate is installed for
// the domain. The subscription URL the panel prints and the listener the
// subscription service opens must answer this question the same way, or clients
// are handed an address that speaks the other protocol, so both ask it here. A
// self-signed pair does not count: clients reject it.
func Usable(domain string) bool {
	_, _, ok := Paths(domain)
	return ok
}

// Domains lists cert domains present in the acme.sh directory. A domain that has
// both an RSA and an EC certificate is listed once: the switch menu acts on the
// domain, not on the flavour.
func Domains() []string {
	seen := map[string]bool{}
	var out []string
	for _, name := range certDirs(ACMEDir()) {
		domain := strings.TrimSuffix(name, "_ecc")
		if domain == "" || seen[domain] {
			continue
		}
		seen[domain] = true
		out = append(out, domain)
	}
	return out
}

// certDirs lists the directories under an acme.sh home that hold a certificate.
func certDirs(dir string) []string {
	entries, err := os.ReadDir(dir)
	if err != nil {
		return nil
	}
	var out []string
	for _, e := range entries {
		if !e.IsDir() {
			continue
		}
		if exists(filepath.Join(dir, e.Name(), "fullchain.cer")) {
			out = append(out, e.Name())
		}
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

// ACMEInstalled reports whether the acme.sh script is available.
func ACMEInstalled() bool {
	for _, p := range []string{ACMESh(), filepath.Join(ACMEDir(), "acme.sh")} {
		if info, err := os.Stat(p); err == nil && isExecutable(info) {
			return true
		}
	}
	return false
}

// isExecutable checks the execute bit where the platform has one. Windows reports
// no permission bits at all, so requiring 0o111 there would mean answer "not
// installed" for a file that is right there, which is what the tests on a Windows
// checkout would otherwise see.
func isExecutable(info os.FileInfo) bool {
	if info.IsDir() {
		return false
	}
	if runtime.GOOS == "windows" {
		return true
	}
	return info.Mode()&0o111 != 0
}

func exists(path string) bool {
	info, err := os.Stat(path)
	return err == nil && info.Size() > 0
}
