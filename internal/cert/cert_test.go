package cert

import (
	"context"
	"errors"
	"net/http"
	"net/http/httptest"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
	"testing"
)

// acmeHome points the package at a throwaway acme.sh home. Every lookup reads
// ACMEDir(), so setting the override keeps the tests off the real HOME, which is
// what os.UserHomeDir() would otherwise hand them on Windows and under sudo.
func acmeHome(t *testing.T) string {
	t.Helper()
	dir := filepath.Join(t.TempDir(), ".acme.sh")
	t.Setenv(ACMEHomeEnv, dir)
	return dir
}

func write(t *testing.T, path, body string, mode os.FileMode) {
	t.Helper()
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, []byte(body), mode); err != nil {
		t.Fatal(err)
	}
}

func TestPathsAndDomains(t *testing.T) {
	dir := acmeHome(t)
	write(t, filepath.Join(dir, "example.com_ecc", "fullchain.cer"), "x", 0o600)
	write(t, filepath.Join(dir, "example.com_ecc", "example.com.key"), "x", 0o600)

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

// TestDomainsListsOncePerDomain guards the switch menu: acme.sh keeps an RSA and
// an EC certificate in separate directories, and both would be offered as the
// same domain.
func TestDomainsListsOncePerDomain(t *testing.T) {
	dir := acmeHome(t)
	for _, name := range []string{"example.com", "example.com_ecc"} {
		write(t, filepath.Join(dir, name, "fullchain.cer"), "x", 0o600)
		write(t, filepath.Join(dir, name, "example.com.key"), "x", 0o600)
	}
	write(t, filepath.Join(dir, "other.com_ecc", "fullchain.cer"), "x", 0o600)

	domains := Domains()
	if len(domains) != 2 {
		t.Fatalf("domains = %v, want one entry per domain", domains)
	}
	seen := map[string]bool{}
	for _, d := range domains {
		if seen[d] {
			t.Fatalf("domain %q listed twice", d)
		}
		seen[d] = true
	}
}

func TestACMEInstalled(t *testing.T) {
	dir := acmeHome(t)
	if ACMEInstalled() {
		t.Fatal("expected acme.sh to be missing")
	}
	write(t, filepath.Join(dir, "acme.sh"), "#!/bin/sh\n", 0o755)
	if !ACMEInstalled() {
		t.Fatal("expected acme.sh to be detected")
	}

	// A file that is not executable is not an installation.
	if err := os.Chmod(filepath.Join(dir, "acme.sh"), 0o644); err != nil {
		t.Fatal(err)
	}
	if runtime.GOOS != "windows" && ACMEInstalled() {
		t.Fatal("a non-executable acme.sh should not count")
	}
}

// TestACMEDirPrefersAnExistingInstallation covers the reason this lookup exists:
// the panel is started from the install script, from sudo and from a systemd unit,
// and only some of those hand it HOME=/root. The check is that a real installation
// under the home directory is found, whichever HOME that is.
func TestACMEDirPrefersAnExistingInstallation(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	t.Setenv("USERPROFILE", home)
	t.Setenv(ACMEHomeEnv, "")

	write(t, filepath.Join(home, ".acme.sh", "acme.sh"), "#!/bin/sh\n", 0o755)
	if got, want := ACMEDir(), filepath.Join(home, ".acme.sh"); got != want {
		t.Fatalf("ACMEDir() = %q, want %q", got, want)
	}

	// An explicit override wins over everything.
	custom := t.TempDir()
	t.Setenv(ACMEHomeEnv, custom)
	if got := ACMEDir(); got != custom {
		t.Fatalf("ACMEDir() = %q, want the override %q", got, custom)
	}
}

// TestLooksLikeACMEHome decides when the /root fallback is worth taking: a
// directory qualifies when it holds the script or certificates, not merely because
// it exists.
func TestLooksLikeACMEHome(t *testing.T) {
	empty := t.TempDir()
	if looksLikeACMEHome(empty) {
		t.Fatal("an empty directory is not an acme.sh home")
	}
	if looksLikeACMEHome(filepath.Join(empty, "missing")) {
		t.Fatal("a missing directory is not an acme.sh home")
	}

	script := t.TempDir()
	write(t, filepath.Join(script, "acme.sh"), "#!/bin/sh\n", 0o755)
	if !looksLikeACMEHome(script) {
		t.Fatal("a directory holding acme.sh is a home")
	}

	// An installation whose script was removed but that still holds issued
	// certificates is worth pointing at too.
	issued := t.TempDir()
	write(t, filepath.Join(issued, "example.com_ecc", "fullchain.cer"), "x", 0o600)
	if !looksLikeACMEHome(issued) {
		t.Fatal("a directory holding certificates is a home")
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

// acmeCrontabOutput is the real acme.sh output that a minimal image without cron
// produces, kept verbatim because the point of errorDetail is what it makes of it:
// the last line is a wiki link, and the reason is four lines above it.
const acmeCrontabOutput = `
It is recommended to install crontab first. Try to install 'cron', 'crontab', 'crontabs' or 'vixie-cron'.
We need to set a cron job to renew the certs automatically.
Otherwise, your certs will not be able to be renewed automatically.
Please add '--force' and try install again to go without crontab.
[Thu Sep 24 08:16:28 UTC 2026] ./acme.sh --install --force
[Thu Sep 24 08:16:28 UTC 2026] Pre-check failed, cannot install.
Install error
中国大陆用户请参考:
https://github.com/acmesh-official/acme.sh/wiki/Install-in-China
`

func TestErrorDetailKeepsTheReason(t *testing.T) {
	got := errorDetail(acmeCrontabOutput)
	if strings.Contains(got, "github.com/acmesh-official") {
		t.Fatalf("errorDetail kept the wiki link instead of the reason: %q", got)
	}
	if !strings.Contains(got, "Pre-check failed") && !strings.Contains(got, "crontab") {
		t.Fatalf("errorDetail lost the reason: %q", got)
	}
	if strings.Contains(got, "[Thu Sep 24") {
		t.Fatalf("errorDetail kept the acme.sh timestamps: %q", got)
	}
}

func TestErrorDetailFallsBackToTheTail(t *testing.T) {
	// A failure with no marked line still has to say something.
	got := errorDetail("line one\nline two\nline three")
	if !strings.Contains(got, "line three") {
		t.Fatalf("errorDetail = %q, want the last lines", got)
	}
}

func TestRenewedDomainsReadsCronOutput(t *testing.T) {
	out := `[Thu Sep 24 03:00:00 UTC 2026] Renew: 'a.example.com'
[Thu Sep 24 03:00:02 UTC 2026] Renew success: 'a.example.com'
[Thu Sep 24 03:00:03 UTC 2026] Renew: 'b.example.com'
[Thu Sep 24 03:00:04 UTC 2026] Skip, next renewal time is: Fri Oct 24 02:00:00 UTC 2026`
	got := renewedDomains(out)
	if len(got) != 1 || got[0] != "a.example.com" {
		t.Fatalf("renewedDomains = %v, want only the renewed domain", got)
	}
}

func TestReportMismatch(t *testing.T) {
	rep := Report{Resolved: []string{"1.2.3.4"}, PublicIP: "1.2.3.4"}
	if rep.Mismatch() {
		t.Fatal("an address that matches this host is not a mismatch")
	}
	rep.Resolved = []string{"5.6.7.8"}
	if !rep.Mismatch() {
		t.Fatal("a domain pointing only elsewhere is a mismatch")
	}
	rep.Resolved = []string{"5.6.7.8", "1.2.3.4"}
	if rep.Mismatch() {
		t.Fatal("one matching address is a match, CDNs round-robin")
	}
	// Without knowing this host's address there is nothing to compare.
	if (Report{Resolved: []string{"5.6.7.8"}}).Mismatch() {
		t.Fatal("an unknown public IP is not a mismatch")
	}
	if (Report{PublicIP: "1.2.3.4"}).Mismatch() {
		t.Fatal("an unresolvable domain is not a mismatch")
	}
}

func TestReportListener(t *testing.T) {
	if (Report{}).Listener() {
		t.Fatal("no socat and no python is not a listener")
	}
	if !(Report{Socat: "/usr/bin/socat"}).Listener() {
		t.Fatal("socat is a listener")
	}
	if !(Report{Python: "/usr/bin/python3"}).Listener() {
		t.Fatal("python is a listener")
	}
}

// TestDownloadFileRejectsShortBodies keeps a captive portal or a truncated
// transfer from being installed as acme.sh and failing later with a syntax error.
// TestRenewalUnitContract locks the unit text that renewal depends on. The panel
// installs acme.sh with --nocron, so these files are the only thing that renews a
// certificate: a typo in a section or a missing --renew-certs would be silent
// until a certificate expires.
func TestRenewalUnitContract(t *testing.T) {
	timer := renewTimerUnit
	for _, want := range []string{"[Timer]", "OnCalendar=daily", "Persistent=true", "[Install]", "WantedBy=timers.target"} {
		if !strings.Contains(timer, want) {
			t.Errorf("timer unit is missing %q", want)
		}
	}

	svc := renewServiceUnit
	for _, want := range []string{"[Service]", "Type=oneshot", "--renew-certs"} {
		if !strings.Contains(svc, want) {
			t.Errorf("service unit is missing %q", want)
		}
	}
	// The command has to come from the format argument, not from a placeholder
	// that was never filled in.
	if !strings.Contains(svc, "ExecStart=%s") {
		t.Error("service unit does not take the executable path")
	}

	if !strings.Contains(renewOpenRC, "%s --renew-certs") {
		t.Error("OpenRC script does not run the renewal command")
	}
}

// TestRenewWithoutAnythingToDo is the gate that keeps the nightly timer from
// restarting a running core: no acme.sh or no certificate has to mean "nothing
// renewed", not "renewed everything".
func TestRenewWithoutAnythingToDo(t *testing.T) {
	acmeHome(t)
	if _, err := Renew(context.Background(), func(string) {}); err == nil {
		t.Fatal("Renew without acme.sh should fail")
	}

	dir := acmeHome(t)
	write(t, filepath.Join(dir, "acme.sh"), "#!/bin/sh\n", 0o755)
	renewed, err := Renew(context.Background(), func(string) {})
	if err != nil {
		t.Fatalf("Renew with no certificates: %v", err)
	}
	if len(renewed) != 0 {
		t.Fatalf("renewed = %v, want none", renewed)
	}
}

func TestDownloadFileRejectsShortBodies(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		_, _ = w.Write([]byte("<html>portal</html>"))
	}))
	defer srv.Close()

	err := downloadFile(context.Background(), srv.URL+"/acme.sh", filepath.Join(t.TempDir(), "acme.sh"))
	if err == nil {
		t.Fatal("a short response should be refused")
	}
}

func TestDownloadFileKeepsTheScript(t *testing.T) {
	body := strings.Repeat("# acme.sh\n", 200)
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		_, _ = w.Write([]byte(body))
	}))
	defer srv.Close()

	dest := filepath.Join(t.TempDir(), "acme.sh")
	if err := downloadFile(context.Background(), srv.URL+"/acme.sh", dest); err != nil {
		t.Fatalf("downloadFile: %v", err)
	}
	got, err := os.ReadFile(dest)
	if err != nil {
		t.Fatal(err)
	}
	if string(got) != body {
		t.Fatalf("downloaded %d bytes, want %d", len(got), len(body))
	}
}

func TestStaging(t *testing.T) {
	t.Setenv(ACMEStagingEnv, "")
	if Staging() {
		t.Fatal("staging should be off by default")
	}
	for _, on := range []string{"1", "true", "yes", "on", "TRUE"} {
		t.Setenv(ACMEStagingEnv, on)
		if !Staging() {
			t.Fatalf("%q should enable staging", on)
		}
	}
	for _, off := range []string{"0", "false", "no", "off", ""} {
		t.Setenv(ACMEStagingEnv, off)
		if Staging() {
			t.Fatalf("%q should not enable staging", off)
		}
	}
}

// timerListed is real `systemctl list-timers easysb-acme.timer --no-pager` output
// taken from a Debian 13 host with the timer running, kept verbatim: the columns
// are fixed width and measured against the header, LAST and PASSED are dashes when
// empty, and NEXT is a five-field timestamp faster than the LEFT column is wide.
const timerListed = "NEXT                        LEFT LAST PASSED UNIT              ACTIVATES\n" +
	"Fri 2026-09-25 01:31:33 UTC  17h -         - easysb-acme.timer easysb-acme.service\n" +
	"\n1 timers listed.\n"

// timerNone is the same command with no timer installed.
const timerNone = "NEXT LEFT PASSED UNIT ACTIVATES\n\n0 timers listed.\n"

func TestParseTimerStatus(t *testing.T) {
	if got, want := parseTimerStatus(timerListed), "Fri 2026-09-25 01:31:33 UTC (17h)"; got != want {
		t.Fatalf("parseTimerStatus = %q, want %q", got, want)
	}
	if got := parseTimerStatus(timerNone); got != "" {
		t.Fatalf("parseTimerStatus of an empty list = %q, want empty", got)
	}
	if got := parseTimerStatus(""); got != "" {
		t.Fatalf("parseTimerStatus of no output = %q, want empty", got)
	}
	if got := parseTimerStatus("nonsense\n"); got != "" {
		t.Fatalf("parseTimerStatus of unparsable output = %q, want empty", got)
	}
}

// TestParseTimerStatusWithoutLeft covers a row whose LEFT column is empty: the
// next run is still worth showing.
func TestParseTimerStatusWithoutLeft(t *testing.T) {
	out := "NEXT                        LEFT LAST PASSED UNIT              ACTIVATES\n" +
		"Fri 2026-09-25 01:31:33 UTC     -         - easysb-acme.timer easysb-acme.service\n"
	if got, want := parseTimerStatus(out), "Fri 2026-09-25 01:31:33 UTC"; got != want {
		t.Fatalf("parseTimerStatus = %q, want %q", got, want)
	}
}

// TestOthersAndStrayAddress cover the failure this panel hit in practice: a domain
// with one correct A record and one stale one. Let's Encrypt validates every
// address, so the stale record fails the order, and the error names that address.
func TestOthersAndStrayAddress(t *testing.T) {
	rep := Report{PublicIP: "154.201.92.132", Resolved: []string{"154.201.92.132", "103.185.248.26"}}
	if got := rep.Others(); len(got) != 1 || got[0] != "103.185.248.26" {
		t.Fatalf("Others() = %v, want [103.185.248.26]", got)
	}
	if rep.Mismatch() {
		t.Fatal("one matching address means this host is among them, not a mismatch")
	}
	if got := (Report{PublicIP: "1.2.3.4", Resolved: []string{"1.2.3.4"}}).Others(); len(got) != 0 {
		t.Fatalf("Others() = %v, want none", got)
	}
	// Without a known public address there is nothing to compare against.
	if got := (Report{Resolved: []string{"1.2.3.4"}}).Others(); len(got) != 0 {
		t.Fatalf("Others() without a public address = %v, want none", got)
	}

	// The text is acme.sh's, with the address and reason in the middle.
	real := errors.New(`issue: dev.example.com: Invalid status. Verification error details: During secondary validation: 103.185.248.26: Fetching http://dev.example.com/.well-known/acme-challenge/abc: Connection refused`)
	if got := StrayAddress(real); got != "103.185.248.26" {
		t.Fatalf("StrayAddress = %q, want 103.185.248.26", got)
	}
	if got := StrayAddress(errors.New("issue: something else went wrong")); got != "" {
		t.Fatalf("StrayAddress of an unrelated error = %q, want empty", got)
	}
	if got := StrayAddress(nil); got != "" {
		t.Fatalf("StrayAddress(nil) = %q, want empty", got)
	}
}

// TestIssueArgs pins the CA. acme.sh's default CA moved from Let's Encrypt to
// ZeroSSL, so relying on it would make the signed certificate depend on the
// installed acme.sh version, and it would not match the staging endpoint.
func TestIssueArgs(t *testing.T) {
	args := issueArgs("dev.example.com", "me@example.com", false)
	joined := strings.Join(args, " ")
	for _, want := range []string{"--issue", "--standalone", "-d dev.example.com", "--keylength ec-256", "--accountemail me@example.com", "--server letsencrypt"} {
		if !strings.Contains(joined, want) {
			t.Errorf("issue args %q missing %q", joined, want)
		}
	}
	if strings.Contains(joined, "letsencrypt_test") {
		t.Errorf("production args must not use the test endpoint: %q", joined)
	}

	staged := strings.Join(issueArgs("dev.example.com", "me@example.com", true), " ")
	if !strings.Contains(staged, "--server letsencrypt_test") {
		t.Errorf("staging args %q must use the test endpoint", staged)
	}
	// A missing email drops the flag instead of passing an empty one.
	if bare := strings.Join(issueArgs("dev.example.com", "  ", false), " "); strings.Contains(bare, "--accountemail") {
		t.Errorf("empty email should not be passed: %q", bare)
	}
}

// TestRenewalLine covers the sentence acme.sh prints when it declines to reissue a
// certificate that is still valid. That case exits non-zero, so the panel has to
// recognise it instead of reporting a failure for a perfectly good certificate.
func TestRenewalLine(t *testing.T) {
	// Real output from acme.sh 3.x on an existing certificate.
	skipped := "[Thu Sep 24 08:46:48 UTC 2026] Domains not changed.\n" +
		"[Thu Sep 24 08:46:48 UTC 2026] Skipping. Next renewal time is: 2026-12-09T08:46:48Z\n" +
		"[Thu Sep 24 08:46:48 UTC 2026] Add '--force' to force renewal.\n"
	if got, want := renewalLine(skipped), "Next renewal time is: 2026-12-09T08:46:48Z"; got != want {
		t.Fatalf("renewalLine = %q, want %q", got, want)
	}
	if got := renewalLine("nothing to see"); got != "" {
		t.Fatalf("renewalLine = %q, want empty", got)
	}
}
