// Package cert resolves TLS certificates for the sing-box server: certificates
// issued by acme.sh when available, otherwise a self-signed placeholder.
package cert

import (
	"context"
	"errors"
	"io"
	"net/http"
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

// ACMEInstalled reports whether the acme.sh script is available.
func ACMEInstalled() bool {
	for _, p := range []string{ACMESh(), filepath.Join(ACMEDir(), "acme.sh")} {
		if info, err := os.Stat(p); err == nil && info.Mode()&0o111 != 0 {
			return true
		}
	}
	return false
}

const acmeInstallerURL = "https://get.acme.sh"

// EnsureACME installs acme.sh when it is missing, using the given account email.
func EnsureACME(ctx context.Context, email string, log func(string)) error {
	if ACMEInstalled() {
		return nil
	}
	if strings.TrimSpace(email) == "" {
		return errors.New("acme email is required")
	}
	installer := filepath.Join(os.TempDir(), "acme-install.sh")
	log("GET " + acmeInstallerURL)
	if err := downloadFile(ctx, acmeInstallerURL, installer); err != nil {
		return err
	}

	cmd := exec.CommandContext(ctx, "sh", installer, "email="+email)
	cmd.Env = append(os.Environ(), "LC_ALL=C")
	out, err := cmd.CombinedOutput()
	if err != nil {
		return errors.New("install acme.sh: " + strings.TrimSpace(string(out)))
	}
	if !ACMEInstalled() {
		return errors.New("acme.sh install did not produce a script")
	}
	return nil
}

// Issue requests a certificate with the acme.sh standalone method.
func Issue(ctx context.Context, domain string, log func(string)) error {
	if !ACMEInstalled() {
		return errors.New("acme.sh is not installed")
	}
	log("$ acme.sh --issue --standalone -d " + domain)
	cmd := exec.CommandContext(ctx, ACMESh(), "--issue", "--standalone", "-d", domain, "--keylength", "ec-256", "--force")
	cmd.Env = append(os.Environ(), "LC_ALL=C")
	out, err := cmd.CombinedOutput()
	if err != nil {
		return errors.New("issue: " + lastLine(string(out)))
	}
	return nil
}

// Remove deletes a certificate managed by acme.sh.
func Remove(ctx context.Context, domain string) error {
	if !ACMEInstalled() {
		return nil
	}
	cmd := exec.CommandContext(ctx, ACMESh(), "--remove", "-d", domain, "--ecc")
	cmd.Env = append(os.Environ(), "LC_ALL=C")
	_, err := cmd.CombinedOutput()
	return err
}

func downloadFile(ctx context.Context, url, dest string) error {
	cctx, cancel := context.WithTimeout(ctx, 60*time.Second)
	defer cancel()
	req, err := http.NewRequestWithContext(cctx, http.MethodGet, url, nil)
	if err != nil {
		return err
	}
	req.Header.Set("User-Agent", "EasySB")
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return errors.New("download " + url + ": " + resp.Status)
	}
	f, err := os.Create(dest)
	if err != nil {
		return err
	}
	defer f.Close()
	_, err = io.Copy(f, resp.Body)
	return err
}

func lastLine(s string) string {
	lines := strings.Split(strings.TrimSpace(s), "\n")
	if len(lines) == 0 {
		return s
	}
	return lines[len(lines)-1]
}

func exists(path string) bool {
	info, err := os.Stat(path)
	return err == nil && info.Size() > 0
}
