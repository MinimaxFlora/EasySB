package cert

import (
	"context"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strings"
	"time"

	"github.com/MinimaxFlora/EasySB/internal/netutil"
)

// ACMEHomeEnv points the panel at a non-default acme.sh home directory. The
// install script and the tests set it.
const ACMEHomeEnv = "EASYSB_ACME_HOME"

// ACMEStagingEnv switches issuance to the Let's Encrypt staging endpoint: the
// certificates are untrusted but the rate limits are not, which is what makes it
// the right endpoint for trying a domain out.
const ACMEStagingEnv = "EASYSB_ACME_STAGING"

// acmeSources are the download locations in order: upstream first, then the mirror
// that stays reachable from networks where GitHub does not.
var acmeSources = []string{
	"https://raw.githubusercontent.com/acmesh-official/acme.sh/master/acme.sh",
	"https://gitee.com/neilpang/acme.sh/raw/master/acme.sh",
}

// EnsureACME installs acme.sh when it is missing, using the given account email.
//
// It runs the release script itself rather than piping get.acme.sh, because that
// wrapper always wants a crontab: on an image without cron it aborts with
// "Pre-check failed, cannot install" and points at the China wiki page, which
// hides the actual reason. Renewal is driven by our own systemd timer, so the
// script is installed with --nocron, and --home pins the directory the rest of
// this package reads from.
func EnsureACME(ctx context.Context, email string, log func(string)) error {
	if ACMEInstalled() {
		return nil
	}
	email = strings.TrimSpace(email)
	if email == "" {
		return errors.New("acme email is required")
	}

	work, err := os.MkdirTemp("", "easysb-acme")
	if err != nil {
		return err
	}
	defer os.RemoveAll(work)

	script := filepath.Join(work, "acme.sh")
	if err := downloadACME(ctx, script, log); err != nil {
		return err
	}
	if err := os.Chmod(script, 0o700); err != nil {
		return err
	}

	dir := ACMEDir()
	log("$ acme.sh --install --nocron --noprofile --home " + dir)
	// acme.sh copies "acme.sh" from its working directory, so it has to run as
	// ./acme.sh from the directory it was downloaded into.
	cmd := exec.CommandContext(ctx, "sh", "./acme.sh", "--install", "--nocron", "--noprofile",
		"--home", dir, "--accountemail", email)
	cmd.Dir = work
	cmd.Env = append(os.Environ(), "LC_ALL=C")
	out, err := cmd.CombinedOutput()
	if err != nil || !ACMEInstalled() {
		return errors.New("install acme.sh: " + errorDetail(string(out)))
	}
	return nil
}

// downloadACME fetches the release script, trying the mirror when upstream fails.
func downloadACME(ctx context.Context, dest string, log func(string)) error {
	var lastErr error
	for _, url := range acmeSources {
		log("GET " + url)
		if err := downloadFile(ctx, url, dest); err == nil {
			return nil
		} else {
			lastErr = err
			log(err.Error())
		}
	}
	return lastErr
}

// acmeCmd runs one acme.sh command against the panel's home directory and returns
// its combined output. --home is passed on every call: acme.sh otherwise derives
// the certificate directory from $HOME, which differs between the install script,
// sudo and the service unit.
func acmeCmd(ctx context.Context, args ...string) (string, error) {
	cmd := exec.CommandContext(ctx, ACMESh(), append(args, "--home", ACMEDir())...)
	cmd.Env = append(os.Environ(), "LC_ALL=C", "LE_WORKING_DIR="+ACMEDir())
	out, err := cmd.CombinedOutput()
	return string(out), err
}

// issueArgs builds the acme.sh command line for one issuance. The CA is pinned
// rather than left to acme.sh's default: that default moved from Let's Encrypt to
// ZeroSSL, so "whatever the installed acme.sh prefers" would silently change which
// CA signs the panel's certificates, and it would split the staging switch below
// (which is Let's Encrypt's test endpoint) from the production CA.
func issueArgs(domain, email string, staging bool) []string {
	args := []string{"--issue", "--standalone", "-d", domain, "--keylength", "ec-256"}
	if strings.TrimSpace(email) != "" {
		args = append(args, "--accountemail", strings.TrimSpace(email))
	}
	server := "letsencrypt"
	if staging {
		server = "letsencrypt_test"
	}
	return append(args, "--server", server)
}

// Issue requests a certificate with the acme.sh standalone method. email is
// remembered by acme.sh as the account address; it is passed again on every issue
// so an installation that predates the panel still ends up registered.
func Issue(ctx context.Context, domain, email string, log func(string)) error {
	if strings.TrimSpace(domain) == "" {
		return errors.New("domain is required")
	}
	if !ACMEInstalled() {
		return errors.New("acme.sh is not installed")
	}

	args := issueArgs(domain, email, Staging())
	log("$ acme.sh " + strings.Join(args, " ") + " --home " + ACMEDir())

	out, err := acmeCmd(ctx, args...)
	// acme.sh refuses to spend an attempt on a certificate that is still valid and
	// exits non-zero with this sentence. That is not a failure: the pair in place is
	// the one that was asked for, so the caller must not be told the issuance broke.
	if strings.Contains(out, "Domains not changed") {
		if next := renewalLine(out); next != "" {
			log("certificate is still valid (" + next + ")")
		}
		return nil
	}
	if err != nil {
		return errors.New("issue: " + errorDetail(out))
	}
	return nil
}

// renewalLine picks acme.sh's "Next renewal time is: …" sentence out of a skipped
// issuance, so the operator is told when the certificate in place expires. The
// sentence sits behind acme.sh's own timestamp prefix, not at the start of the line.
func renewalLine(out string) string {
	for _, line := range strings.Split(out, "\n") {
		if at := strings.Index(line, "Next renewal time is:"); at >= 0 {
			return strings.TrimSpace(line[at:])
		}
	}
	return ""
}

// Renew runs the acme.sh renewal pass. It is what the systemd timer calls, and it
// is the reason this package does not need a crontab.
// Renew runs one renewal pass over everything acme.sh manages and reports which
// domains were actually renewed. The caller uses that answer to decide whether the
// services need reloading: a renewal that changed nothing must not restart a
// running core, and the timer runs this every night.
func Renew(ctx context.Context, log func(string)) ([]string, error) {
	if !ACMEInstalled() {
		return nil, errors.New("acme.sh is not installed")
	}
	if len(Domains()) == 0 {
		return nil, nil
	}
	log("$ acme.sh --cron --home " + ACMEDir())
	out, err := acmeCmd(ctx, "--cron")
	if err != nil {
		return nil, errors.New("renew: " + errorDetail(out))
	}
	renewed := renewedDomains(out)
	if len(renewed) > 0 {
		log("renewed: " + strings.Join(renewed, ", "))
	}
	return renewed, nil
}

// Remove deletes a certificate managed by acme.sh.
func Remove(ctx context.Context, domain string) error {
	if !ACMEInstalled() {
		return nil
	}
	out, err := acmeCmd(ctx, "--remove", "-d", domain, "--ecc")
	if err != nil {
		return errors.New("remove: " + errorDetail(out))
	}
	return nil
}

// Staging reports whether issuance should use the Let's Encrypt staging endpoint.
func Staging() bool {
	switch strings.ToLower(strings.TrimSpace(os.Getenv(ACMEStagingEnv))) {
	case "1", "true", "yes", "on":
		return true
	}
	return false
}

// Report is what can be checked about a domain before spending an ACME attempt on
// it. Every field is a fact rather than a verdict: a domain behind a CDN resolves
// to addresses that are not this server and is still issuable, so the caller
// decides what to do with the combination.
type Report struct {
	Socat    string // path to socat, empty when missing
	Python   string // path to a python interpreter, empty when missing
	Resolved []string
	PublicIP string
	DNSFail  error
}

// Listener reports whether the standalone challenge has something to bind with.
func (r Report) Listener() bool { return r.Socat != "" || r.Python != "" }

// Mismatch reports whether the domain resolves somewhere else. An empty PublicIP
// means the panel could not work out this server's address, which is not a
// mismatch, only an unknown.
func (r Report) Mismatch() bool {
	if r.PublicIP == "" || len(r.Resolved) == 0 {
		return false
	}
	for _, ip := range r.Resolved {
		if ip == r.PublicIP {
			return false
		}
	}
	return true
}

// Others are the resolved addresses that are not this server. A domain with one of
// these is not necessarily broken: Let's Encrypt validates a challenge against
// every address a domain resolves to, so a stale record pointing at a host that no
// longer exists fails the whole order with a connection error on that address, while
// the address of this server passes. It is worth saying out loud before the attempt.
func (r Report) Others() []string {
	if r.PublicIP == "" {
		return nil
	}
	var others []string
	for _, ip := range r.Resolved {
		if ip != r.PublicIP {
			others = append(others, ip)
		}
	}
	return others
}

// secondaryValidation matches the address Let's Encrypt names when a remote
// perspective fails to reach the domain:
//
//	During secondary validation: 203.0.113.9: Fetching …: Connection refused
var secondaryValidation = regexp.MustCompile(`During secondary validation: ([0-9a-fA-F.:]+):`)

// StrayAddress returns the address a failed secondary validation could not reach.
// Combined with Report.Others it explains the failure: the address in the error is
// the stale record, and removing it is the fix.
func StrayAddress(issueErr error) string {
	if issueErr == nil {
		return ""
	}
	m := secondaryValidation.FindStringSubmatch(issueErr.Error())
	if len(m) < 2 {
		return ""
	}
	return strings.Trim(m[1], "[]")
}

// Preflight gathers the facts an operator needs before issuing: whether a
// standalone listener is available and where the domain currently points.
func Preflight(ctx context.Context, domain string) Report {
	rep := Report{
		Socat:  lookupTool("socat"),
		Python: firstTool("python3", "python", "python2"),
	}
	dctx, cancel := context.WithTimeout(ctx, 8*time.Second)
	defer cancel()
	if ips, err := net.DefaultResolver.LookupHost(dctx, domain); err != nil {
		rep.DNSFail = err
	} else {
		rep.Resolved = ips
	}
	if ip, err := netutil.PublicIP(dctx); err == nil {
		rep.PublicIP = ip
	}
	return rep
}

// CheckPort80 reports why the standalone challenge cannot bind port 80. It is
// called after the core is stopped, because the core is what usually holds it.
func CheckPort80() error {
	ln, err := net.Listen("tcp", ":80")
	if err != nil {
		return fmt.Errorf("%w (%s)", err, port80Holder())
	}
	return ln.Close()
}

// port80Holder names the process holding port 80 when ss can tell us. It is
// best-effort: an empty result just means the error message stays shorter.
func port80Holder() string {
	if _, err := exec.LookPath("ss"); err != nil {
		return "no ss to name the holder"
	}
	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
	defer cancel()
	out, err := exec.CommandContext(ctx, "ss", "-ltnpH", "sport = :80").Output()
	if err != nil {
		return ""
	}
	line := strings.Join(strings.Fields(string(out)), " ")
	if len(line) > 120 {
		line = line[:120]
	}
	return line
}

func lookupTool(name string) string {
	if p, err := exec.LookPath(name); err == nil {
		return p
	}
	return ""
}

func firstTool(names ...string) string {
	for _, name := range names {
		if p := lookupTool(name); p != "" {
			return p
		}
	}
	return ""
}

// renewedDomains pulls the domains acme.sh reports as renewed out of a --cron run.
func renewedDomains(out string) []string {
	var got []string
	for _, line := range strings.Split(out, "\n") {
		if !strings.Contains(line, "Cert success") && !strings.Contains(line, "Renew success") {
			continue
		}
		if domain := domainInLine(line); domain != "" {
			got = append(got, domain)
		}
	}
	return got
}

// domainInLine extracts the domain from an acme.sh log line such as
// "[Thu ...] Renew: 'example.com'". It returns "" when the line carries none.
func domainInLine(line string) string {
	if i := strings.Index(line, "'"); i >= 0 {
		if j := strings.Index(line[i+1:], "'"); j > 0 {
			return line[i+1 : i+1+j]
		}
	}
	return ""
}

// errorDetail picks the lines worth showing when a command fails. acme.sh prints
// several progress lines before the reason, so the last line alone ("Install
// error" or "Please add '--force'") would hide it, and the full output would bury
// it. Lines that name a cause come first, then the tail as a fallback.
func errorDetail(out string) string {
	var hits, tail []string
	for _, raw := range strings.Split(out, "\n") {
		line := stripLogPrefix(strings.TrimSpace(raw))
		if line == "" {
			continue
		}
		if len(tail) == 4 {
			tail = tail[1:]
		}
		tail = append(tail, line)
		if isCause(line) {
			hits = append(hits, line)
		}
	}
	if len(hits) > 3 {
		hits = hits[len(hits)-3:]
	}
	if len(hits) == 0 {
		hits = tail
	}
	return strings.Join(hits, " | ")
}

// stripLogPrefix removes acme.sh's "[Thu Sep 24 08:16:28 UTC 2026] " timestamp.
func stripLogPrefix(line string) string {
	if !strings.HasPrefix(line, "[") {
		return line
	}
	if end := strings.Index(line, "] "); end > 0 {
		return strings.TrimSpace(line[end+2:])
	}
	return line
}

// isCause marks the lines that explain a failure rather than describe progress.
func isCause(line string) bool {
	for _, marker := range []string{"error", "Error", "fail", "Fail", "Please", "cannot", "Cannot", "refused", "denied", "not exist", "timed out", "Timeout"} {
		if strings.Contains(line, marker) {
			return true
		}
	}
	return false
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
	if _, err := io.Copy(f, resp.Body); err != nil {
		return err
	}
	// A captive portal or a truncated transfer would otherwise leave a script
	// that fails much later with a syntax error.
	if info, err := f.Stat(); err != nil || info.Size() < 1024 {
		return errors.New("download " + url + ": response too small to be acme.sh")
	}
	return nil
}
