package front

import (
	"context"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/pem"
	"math/big"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

// The routing decision is the whole design: the subscription endpoint answers under
// /sub/, everything else belongs to the application, which is what makes the domain
// look like an ordinary site.
func TestExactlyTheSubscriptionPathGoesToTheSubscriptionService(t *testing.T) {
	site := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Write([]byte("application:" + r.URL.Path))
	}))
	defer site.Close()

	sub := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Write([]byte("subscription"))
	})

	handler := Handler(Options{AppTarget: strings.TrimPrefix(site.URL, "http://"), Sub: sub, App: "OpenList"})

	cases := []struct {
		path string
		want string
	}{
		{"/", "application:/"},
		{"/index.html", "application:/index.html"},
		{"/assets/app.js", "application:/assets/app.js"},
		{"/sub/TOKEN", "subscription"},
		{"/subscription", "application:/subscription"},
		{"/sub", "application:/sub"},
		{"/dashboard/sub/x", "application:/dashboard/sub/x"},
	}
	for _, c := range cases {
		rec := httptest.NewRecorder()
		handler.ServeHTTP(rec, httptest.NewRequest(http.MethodGet, c.path, nil))
		if got := rec.Body.String(); got != c.want {
			t.Errorf("%s -> %q, want %q", c.path, got, c.want)
		}
	}
}

// A site whose application is down answers with a proxy error rather than with the
// panel's own pages: it has to look like a site with a problem, not like a panel.
func TestUnreachableApplicationIsABadGateway(t *testing.T) {
	handler := Handler(Options{AppTarget: "127.0.0.1:1", App: "Memos", Log: func(string) {}})
	rec := httptest.NewRecorder()
	handler.ServeHTTP(rec, httptest.NewRequest(http.MethodGet, "/", nil))
	if rec.Code != http.StatusBadGateway {
		t.Fatalf("status = %d, want 502", rec.Code)
	}
	if strings.Contains(rec.Body.String(), "EasySB") {
		t.Errorf("the error page names the panel: %q", rec.Body.String())
	}
}

// Without a subscription handler the whole domain belongs to the application, which
// is the state before any account exists.
func TestWithoutSubscriptionEverythingIsTheApplication(t *testing.T) {
	site := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Write([]byte("application"))
	}))
	defer site.Close()

	handler := Handler(Options{AppTarget: strings.TrimPrefix(site.URL, "http://"), App: "Nezha"})
	rec := httptest.NewRecorder()
	handler.ServeHTTP(rec, httptest.NewRequest(http.MethodGet, "/sub/TOKEN", nil))
	if got := rec.Body.String(); got != "application" {
		t.Errorf("/sub/ -> %q, want the application", got)
	}
}

// The access log is what tells a real visitor from a scanner, so it records the
// client, the host, the method, the target and the status.
func TestAccessLogRecordsTheRequest(t *testing.T) {
	dir := t.TempDir()
	logFile := filepath.Join(dir, "front.log")

	site := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusTeapot)
	}))
	defer site.Close()

	handler := Handler(Options{AppTarget: strings.TrimPrefix(site.URL, "http://"), App: "OpenList", LogFile: logFile})
	req := httptest.NewRequest(http.MethodGet, "/login", nil)
	req.Host = "us.example.com"
	req.RemoteAddr = "203.0.113.9:51234"
	req.Header.Set("User-Agent", "masscan")
	handler.ServeHTTP(httptest.NewRecorder(), req)

	body, err := os.ReadFile(logFile)
	if err != nil {
		t.Fatalf("no access log: %v", err)
	}
	line := string(body)
	for _, want := range []string{"203.0.113.9", "us.example.com", "GET", "/login", "418", "masscan"} {
		if !strings.Contains(line, want) {
			t.Errorf("access log %q is missing %q", line, want)
		}
	}
}

// The log is compacted instead of growing without bound: a probe storm must not be
// able to fill the disk.
func TestAccessLogIsCompacted(t *testing.T) {
	file := filepath.Join(t.TempDir(), "front.log")
	for i := 0; i < keepLogLines+50; i++ {
		appendLog(file, "line "+strings.Repeat("x", 64))
	}
	info, err := os.Stat(file)
	if err != nil {
		t.Fatal(err)
	}
	// Push the file past the compaction point, then check it was cut back.
	if err := os.WriteFile(file, []byte(strings.Repeat("padding\n", int(maxLogBytes/8))), 0o644); err != nil {
		t.Fatal(err)
	}
	appendLog(file, "last")
	info, err = os.Stat(file)
	if err != nil {
		t.Fatal(err)
	}
	if info.Size() > maxLogBytes {
		t.Fatalf("log is %d bytes after compaction, want <= %d", info.Size(), maxLogBytes)
	}
	body, err := os.ReadFile(file)
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(body), "last") {
		t.Error("compaction dropped the newest line")
	}
}

// Without a certificate the front refuses to start: a self-signed site is worse than
// no site, because a client would see a certificate error where a scanner sees a
// plain closed port.
func TestRunRefusesWithoutACertificate(t *testing.T) {
	err := Run(context.Background(), Options{Listen: ":0", Domain: "us.example.com"})
	if err == nil {
		t.Fatal("Run should refuse without a certificate")
	}
	if !strings.Contains(err.Error(), "certificate") {
		t.Errorf("error = %v, want it to name the missing certificate", err)
	}
}

// writeSelfSigned writes a throwaway certificate and key pair, so the test needs no
// openssl and no network. A renewal is simulated by touching the file's mtime, which
// is what the loader watches: two renewals cannot land in the same second in
// practice, and the test says so explicitly rather than relying on timing.
func writeSelfSigned(t *testing.T, certFile, keyFile string) {
	t.Helper()

	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	tmpl := &x509.Certificate{
		SerialNumber: big.NewInt(time.Now().UnixNano()),
		Subject:      pkix.Name{CommonName: "us.example.com"},
		NotBefore:    time.Now().Add(-time.Hour),
		NotAfter:     time.Now().Add(24 * time.Hour),
		DNSNames:     []string{"us.example.com"},
	}
	der, err := x509.CreateCertificate(rand.Reader, tmpl, tmpl, &key.PublicKey, key)
	if err != nil {
		t.Fatal(err)
	}
	pemCert := pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: der})
	der2, err := x509.MarshalECPrivateKey(key)
	if err != nil {
		t.Fatal(err)
	}
	pemKey := pem.EncodeToMemory(&pem.Block{Type: "EC PRIVATE KEY", Bytes: der2})

	if err := os.WriteFile(certFile, pemCert, 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(keyFile, pemKey, 0o600); err != nil {
		t.Fatal(err)
	}
	// Push the modification time forward so a rewrite within the same second is a
	// visible change, the way a real renewal is.
	stamp := time.Now().Add(2 * time.Second)
	if err := os.Chtimes(certFile, stamp, stamp); err != nil {
		t.Fatal(err)
	}
}

func TestCertificateIsReloadedAfterRenewal(t *testing.T) {
	dir := t.TempDir()
	certFile := filepath.Join(dir, "fullchain.cer")
	keyFile := filepath.Join(dir, "private.key")
	writeSelfSigned(t, certFile, keyFile)

	loader, err := newCertLoader(certFile, keyFile)
	if err != nil {
		t.Fatalf("loading the first certificate: %v", err)
	}
	first, err := loader.get(nil)
	if err != nil {
		t.Fatal(err)
	}

	writeSelfSigned(t, certFile, keyFile)
	second, err := loader.get(nil)
	if err != nil {
		t.Fatalf("loading the renewed certificate: %v", err)
	}
	if first == second {
		t.Error("the loader kept serving the old certificate")
	}
}
