package cert

import (
	"context"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/tls"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/base64"
	"encoding/json"
	"encoding/pem"
	"fmt"
	"io"
	"math/big"
	"net"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/go-acme/lego/v5/challenge"
	"github.com/go-acme/lego/v5/challenge/http01"
)

// fakeCA issues the leaves the fake ACME server hands out. Signing a real CSR is
// what makes the end-to-end test meaningful: the pair the panel writes has to load
// as a TLS certificate, which it only does if the key it stored matches the
// certificate the CA signed.
type fakeCA struct {
	cert    *x509.Certificate
	key     *ecdsa.PrivateKey
	certPEM []byte
}

func newFakeCA(t *testing.T) *fakeCA {
	t.Helper()
	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	template := &x509.Certificate{
		SerialNumber:          big.NewInt(1),
		Subject:               pkix.Name{CommonName: "EasySB test CA"},
		NotBefore:             time.Now().Add(-time.Hour),
		NotAfter:              time.Now().AddDate(5, 0, 0),
		IsCA:                  true,
		KeyUsage:              x509.KeyUsageCertSign | x509.KeyUsageDigitalSignature,
		BasicConstraintsValid: true,
	}
	der, err := x509.CreateCertificate(rand.Reader, template, template, &key.PublicKey, key)
	if err != nil {
		t.Fatal(err)
	}
	cert, err := x509.ParseCertificate(der)
	if err != nil {
		t.Fatal(err)
	}
	return &fakeCA{cert: cert, key: key, certPEM: pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: der})}
}

// sign issues a leaf for the CSR the client built, valid for days.
func (ca *fakeCA) sign(t *testing.T, csr *x509.CertificateRequest, days int) *x509.Certificate {
	t.Helper()
	serial, err := rand.Int(rand.Reader, new(big.Int).Lsh(big.NewInt(1), 96))
	if err != nil {
		t.Fatal(err)
	}
	template := &x509.Certificate{
		SerialNumber:          serial,
		Subject:               csr.Subject,
		DNSNames:              csr.DNSNames,
		NotBefore:             time.Now().Add(-time.Hour),
		NotAfter:              time.Now().AddDate(0, 0, days),
		KeyUsage:              x509.KeyUsageDigitalSignature,
		ExtKeyUsage:           []x509.ExtKeyUsage{x509.ExtKeyUsageServerAuth},
		BasicConstraintsValid: true,
	}
	der, err := x509.CreateCertificate(rand.Reader, template, ca.cert, csr.PublicKey, ca.key)
	if err != nil {
		t.Fatal(err)
	}
	leaf, err := x509.ParseCertificate(der)
	if err != nil {
		t.Fatal(err)
	}
	return leaf
}

// acmeServer is a throwaway ACME server: it answers the directory, account, order,
// challenge and certificate requests a client makes, without verifying a single
// signature. It is not an ACME implementation and does not try to be one; what it
// does is run the panel's own issuance path end to end against the real lego
// client, so a mistake in how that client is configured — a missing provider, the
// wrong CA URL, a certificate written under the wrong name — fails here instead of
// on a host that has already spent a rate limit.
type acmeServer struct {
	t   *testing.T
	ca  *fakeCA
	srv *httptest.Server

	mu       sync.Mutex
	requests int
	accounts int
	domain   string
	leafDays int
	leafPEM  []byte
	serials  []string
}

func newACMEServer(t *testing.T) *acmeServer {
	t.Helper()
	s := &acmeServer{t: t, ca: newFakeCA(t), leafDays: 90}

	mux := http.NewServeMux()
	mux.HandleFunc("/directory", s.handleDirectory)
	mux.HandleFunc("/new-nonce", func(w http.ResponseWriter, _ *http.Request) { w.WriteHeader(http.StatusOK) })
	mux.HandleFunc("/new-account", s.handleNewAccount)
	mux.HandleFunc("/new-order", s.handleNewOrder)
	mux.HandleFunc("/authz", s.handleAuthorization)
	mux.HandleFunc("/challenge", s.handleChallenge)
	mux.HandleFunc("/finalize", s.handleFinalize)
	mux.HandleFunc("/cert", s.handleCertificate)

	var nonce int64
	s.srv = httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		// Every response carries a fresh nonce, which is what a real ACME server
		// does and what lets the client send the next signed request.
		nonce++
		w.Header().Set("Replay-Nonce", fmt.Sprintf("nonce-%d", nonce))
		s.mu.Lock()
		s.requests++
		s.mu.Unlock()
		mux.ServeHTTP(w, r)
	}))
	t.Cleanup(s.srv.Close)
	return s
}

func (s *acmeServer) url(path string) string { return s.srv.URL + path }

func (s *acmeServer) requestCount() int {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.requests
}

func (s *acmeServer) accountCount() int {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.accounts
}

func (s *acmeServer) setLeafDays(days int) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.leafDays = days
}

// currentDomain is the domain of the last order, which is what the authorization
// and the certificate are built for.
func (s *acmeServer) currentDomain() string {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.domain
}

func (s *acmeServer) writeJSON(w http.ResponseWriter, status int, body any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	if err := json.NewEncoder(w).Encode(body); err != nil {
		s.t.Errorf("write ACME response: %v", err)
	}
}

func (s *acmeServer) handleDirectory(w http.ResponseWriter, _ *http.Request) {
	s.writeJSON(w, http.StatusOK, map[string]string{
		"newNonce":   s.url("/new-nonce"),
		"newAccount": s.url("/new-account"),
		"newOrder":   s.url("/new-order"),
		"revokeCert": s.url("/revoke"),
		"keyChange":  s.url("/key-change"),
	})
}

func (s *acmeServer) handleNewAccount(w http.ResponseWriter, _ *http.Request) {
	s.mu.Lock()
	s.accounts++
	s.mu.Unlock()
	w.Header().Set("Location", s.url("/account/1"))
	s.writeJSON(w, http.StatusCreated, map[string]any{"status": "valid"})
}

func (s *acmeServer) handleNewOrder(w http.ResponseWriter, r *http.Request) {
	domain := s.identifier(s.payload(r))
	s.mu.Lock()
	s.domain = domain
	s.mu.Unlock()

	w.Header().Set("Location", s.url("/order/1"))
	s.writeJSON(w, http.StatusCreated, map[string]any{
		"status":         "pending",
		"identifiers":    []map[string]string{{"type": "dns", "value": domain}},
		"authorizations": []string{s.url("/authz")},
		"finalize":       s.url("/finalize"),
	})
}

// handleAuthorization answers with a pending authorization carrying one HTTP-01
// challenge, which is the only challenge the panel can solve.
func (s *acmeServer) handleAuthorization(w http.ResponseWriter, _ *http.Request) {
	s.writeJSON(w, http.StatusOK, map[string]any{
		"status":     "pending",
		"identifier": map[string]string{"type": "dns", "value": s.currentDomain()},
		"challenges": []map[string]string{{
			"type":   "http-01",
			"url":    s.url("/challenge"),
			"token":  "test-token",
			"status": "pending",
		}},
	})
}

// handleChallenge reports the challenge as already valid, which is how a real CA
// answers a request that has just been validated. Returning it valid skips the
// client's polling loop, so the test does not wait out its backoff.
func (s *acmeServer) handleChallenge(w http.ResponseWriter, _ *http.Request) {
	s.writeJSON(w, http.StatusOK, map[string]string{
		"type":   "http-01",
		"url":    s.url("/challenge"),
		"token":  "test-token",
		"status": "valid",
	})
}

// handleFinalize signs the CSR the client sent, so the certificate the panel ends
// up storing really belongs to the key it generated.
func (s *acmeServer) handleFinalize(w http.ResponseWriter, r *http.Request) {
	raw, err := base64.RawURLEncoding.DecodeString(stringOr(s.payload(r)["csr"]))
	if err != nil {
		s.t.Errorf("finalize: decode csr: %v", err)
	}
	csr, err := x509.ParseCertificateRequest(raw)
	if err != nil {
		s.t.Errorf("finalize: parse csr: %v", err)
	}

	s.mu.Lock()
	days := s.leafDays
	domain := s.domain
	s.mu.Unlock()
	leaf := s.ca.sign(s.t, csr, days)
	leafPEM := pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: leaf.Raw})

	s.mu.Lock()
	s.leafPEM = leafPEM
	s.serials = append(s.serials, leaf.SerialNumber.String())
	s.mu.Unlock()

	w.Header().Set("Location", s.url("/order/1"))
	s.writeJSON(w, http.StatusOK, map[string]any{
		"status":      "valid",
		"identifiers": []map[string]string{{"type": "dns", "value": domain}},
		"finalize":    s.url("/finalize"),
		"certificate": s.url("/cert"),
	})
}

// handleCertificate serves the chain the client stores as fullchain.cer: the leaf
// the finalize step signed, followed by the CA, which is the order a fullchain is
// read in.
func (s *acmeServer) handleCertificate(w http.ResponseWriter, _ *http.Request) {
	s.mu.Lock()
	leafPEM := s.leafPEM
	s.mu.Unlock()
	if len(leafPEM) == 0 {
		s.t.Error("the certificate was fetched before it was finalized")
		http.Error(w, "no certificate", http.StatusInternalServerError)
		return
	}

	w.Header().Set("Content-Type", "application/pem-certificate-chain")
	w.WriteHeader(http.StatusOK)
	if _, err := w.Write(append(leafPEM, s.ca.certPEM...)); err != nil {
		s.t.Errorf("write certificate: %v", err)
	}
}

// issueCount is how many certificates the CA has signed, which is how a test can
// tell a renewal from a reissue of the same pair.
func (s *acmeServer) issueCount() int {
	s.mu.Lock()
	defer s.mu.Unlock()
	return len(s.serials)
}

// payload decodes the JWS body of an ACME request. Signatures are not verified:
// the requests this server answers are built by a real client, and what the
// responses need from them is the domain and the CSR.
func (s *acmeServer) payload(r *http.Request) map[string]any {
	body, err := io.ReadAll(r.Body)
	if err != nil {
		s.t.Errorf("read request: %v", err)
		return nil
	}
	var envelope struct {
		Payload string `json:"payload"`
	}
	if err := json.Unmarshal(body, &envelope); err != nil {
		s.t.Errorf("request is not a JWS envelope: %v", err)
		return nil
	}
	raw, err := base64.RawURLEncoding.DecodeString(envelope.Payload)
	if err != nil {
		s.t.Errorf("decode payload: %v", err)
		return nil
	}
	var out map[string]any
	if err := json.Unmarshal(raw, &out); err != nil {
		s.t.Errorf("decode payload json: %v", err)
		return nil
	}
	return out
}

// identifier pulls the first identifier value out of an order request.
func (s *acmeServer) identifier(payload map[string]any) string {
	identifiers, _ := payload["identifiers"].([]any)
	if len(identifiers) == 0 {
		s.t.Error("the order carries no identifier")
		return ""
	}
	first, _ := identifiers[0].(map[string]any)
	return stringOr(first["value"])
}

func stringOr(value any) string {
	s, _ := value.(string)
	return s
}

// recordingProvider is the challenge listener the tests inject: the real HTTP-01
// server, on a spare address rather than port 80, wrapped so a test can see which
// token was presented, check that the listener really answered it over HTTP, and
// see that it was closed again afterwards.
type recordingProvider struct {
	t         *testing.T
	inner     challenge.Provider
	address   string
	presented []string
	cleaned   []string
}

func newRecordingProvider(t *testing.T) *recordingProvider {
	t.Helper()
	// Bind a port to find a free one, then hand it to the provider. The CA fetches
	// the challenge from http://<domain>:80 in production, which a test must not
	// claim, so the address is the only thing that changes here.
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	address := ln.Addr().String()
	if err := ln.Close(); err != nil {
		t.Fatal(err)
	}
	host, port, err := net.SplitHostPort(address)
	if err != nil {
		t.Fatal(err)
	}
	return &recordingProvider{t: t, inner: http01.NewProviderServer(host, port), address: address}
}

func (p *recordingProvider) Present(ctx context.Context, domain, token, keyAuth string) error {
	if err := p.inner.Present(ctx, domain, token, keyAuth); err != nil {
		return err
	}
	// What the CA does next, done here instead: fetch the token over plain HTTP
	// and compare it with the key authorization the challenge was built from. The
	// Host header is the domain, because the listener answers only for the name it
	// was presented for — the check that keeps it from being a reflector.
	served, err := p.fetch(domain, token)
	if err != nil {
		return err
	}
	if served != keyAuth {
		return fmt.Errorf("challenge response = %q, want the key authorization", served)
	}
	// The same request under another name must not be answered.
	if other, err := p.fetch("someone-else.example.com", token); err == nil && other == keyAuth {
		return fmt.Errorf("the challenge listener answered for %q", "someone-else.example.com")
	}
	p.presented = append(p.presented, domain+" "+token)
	return nil
}

// fetch asks the listener for a token under a given name.
func (p *recordingProvider) fetch(host, token string) (string, error) {
	req, err := http.NewRequest(http.MethodGet, "http://"+p.address+http01.ChallengePath(token), nil)
	if err != nil {
		return "", err
	}
	req.Host = host
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		return "", fmt.Errorf("the challenge listener did not answer: %w", err)
	}
	defer resp.Body.Close()
	body, err := io.ReadAll(resp.Body)
	if err != nil {
		return "", err
	}
	return strings.TrimSpace(string(body)), nil
}

func (p *recordingProvider) CleanUp(ctx context.Context, domain, token, keyAuth string) error {
	p.cleaned = append(p.cleaned, token)
	return p.inner.CleanUp(ctx, domain, token, keyAuth)
}

// useFakeCA points the package at a throwaway ACME server and a challenge listener
// that does not need port 80, and puts the production values back when the test
// ends, so a seam cannot leak into the next test.
func useFakeCA(t *testing.T, srv *acmeServer) (*recordingProvider, string) {
	t.Helper()
	dir := filepath.Join(t.TempDir(), "acme")
	t.Setenv(DirEnv, dir)
	rec := newRecordingProvider(t)
	directoryFor = func(bool) string { return srv.url("/directory") }
	httpClient = func() *http.Client { return srv.srv.Client() }
	challengeProvider = func() challenge.Provider { return rec }
	t.Cleanup(func() {
		directoryFor = letsEncryptDirectory
		httpClient = func() *http.Client { return nil }
		challengeProvider = standaloneChallenge
	})
	return rec, dir
}

// registerAccount plants the account the panel stores after its first issuance, so
// a test can exercise a later path without running an issuance first.
func registerAccount(t *testing.T, dir, location string) {
	t.Helper()
	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	keyDER, err := x509.MarshalECPrivateKey(key)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.MkdirAll(dir, 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(dir, accountKeyName),
		pem.EncodeToMemory(&pem.Block{Type: "EC PRIVATE KEY", Bytes: keyDER}), 0o600); err != nil {
		t.Fatal(err)
	}
	data, err := json.Marshal(storedRegistration{Location: location})
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(dir, accountJSONName), data, 0o600); err != nil {
		t.Fatal(err)
	}
}

func collect(lines *[]string) func(string) {
	return func(line string) { *lines = append(*lines, line) }
}

func TestIssueObtainsAndInstallsACertificate(t *testing.T) {
	srv := newACMEServer(t)
	rec, dir := useFakeCA(t, srv)

	var lines []string
	domain := "dev.example.com"
	if Registered() {
		t.Fatal("a panel that has never issued anything has no account")
	}
	if err := Issue(context.Background(), domain, "me@example.com", collect(&lines)); err != nil {
		t.Fatalf("Issue: %v\nlog:\n%s", err, strings.Join(lines, "\n"))
	}
	if !Registered() {
		t.Error("the account was not stored")
	}

	// The pair is what the rest of the tree reads, so it has to load as a TLS
	// certificate whose key and certificate belong together.
	fullchain, key, ok := Paths(domain)
	if !ok {
		t.Fatal("no certificate pair was written")
	}
	pair, err := tls.LoadX509KeyPair(fullchain, key)
	if err != nil {
		t.Fatalf("the installed pair does not load: %v", err)
	}
	leaf, err := x509.ParseCertificate(pair.Certificate[0])
	if err != nil {
		t.Fatal(err)
	}
	if len(leaf.DNSNames) != 1 || leaf.DNSNames[0] != domain {
		t.Errorf("the certificate names %v, want [%s]", leaf.DNSNames, domain)
	}
	if len(pair.Certificate) < 2 {
		t.Error("fullchain.cer does not carry the issuer certificate")
	}
	if !Usable(domain) {
		t.Error("the issued pair should be usable")
	}
	if got := Domains(); len(got) != 1 || got[0] != domain {
		t.Errorf("Domains() = %v, want [%s]", got, domain)
	}
	if expiry, err := expiryOf(domain); err != nil || expiry.Before(time.Now().AddDate(0, 0, 80)) {
		t.Errorf("expiry = %v (%v), want the CA's 90 days", expiry, err)
	}

	// The challenge was presented, really answered over HTTP, and cleaned up.
	if len(rec.presented) != 1 || !strings.HasPrefix(rec.presented[0], domain+" ") {
		t.Errorf("presented = %v, want the domain's token", rec.presented)
	}
	if len(rec.cleaned) != 1 {
		t.Errorf("cleaned = %v, want the token to be removed", rec.cleaned)
	}

	// The account URL is stored, and registering happened exactly once.
	data, err := os.ReadFile(filepath.Join(dir, accountJSONName))
	if err != nil {
		t.Fatalf("the account was not stored: %v", err)
	}
	var stored storedRegistration
	if err := json.Unmarshal(data, &stored); err != nil {
		t.Fatalf("parse stored account: %v", err)
	}
	if !strings.Contains(stored.Location, "/account/") {
		t.Errorf("stored account URL = %q, want the CA's account location", stored.Location)
	}
	if got := srv.accountCount(); got != 1 {
		t.Errorf("registration requests = %d, want 1", got)
	}
	if runtime.GOOS != "windows" {
		info, err := os.Stat(key)
		if err != nil {
			t.Fatal(err)
		}
		if info.Mode().Perm() != 0o600 {
			t.Errorf("private key mode = %v, want 0600", info.Mode().Perm())
		}
	}
}

// TestIssueLeavesAValidCertificateAlone is the rate limit guard: acme.sh refused
// to reissue a certificate whose domains had not changed, and the panel has to
// behave the same way, or a second click costs one of the five duplicate
// certificates Let's Encrypt allows a week.
func TestIssueLeavesAValidCertificateAlone(t *testing.T) {
	srv := newACMEServer(t)
	_, dir := useFakeCA(t, srv)
	domain := "dev.example.com"
	writePair(t, dir, domain, time.Now().AddDate(0, 0, 60))
	expected, err := expiryOf(domain)
	if err != nil {
		t.Fatal(err)
	}

	// Nothing may reach the CA, so the CA is made unreachable on purpose.
	directoryFor = func(bool) string {
		t.Error("a certificate that is still valid must not cost a request")
		return srv.url("/directory")
	}

	var lines []string
	if err := Issue(context.Background(), domain, "me@example.com", collect(&lines)); err != nil {
		t.Fatalf("Issue: %v", err)
	}
	got, err := expiryOf(domain)
	if err != nil {
		t.Fatal(err)
	}
	if !got.Equal(expected) {
		t.Errorf("the certificate was replaced: %s -> %s", expected, got)
	}
	if joined := strings.Join(lines, "\n"); !strings.Contains(joined, "still valid") {
		t.Errorf("the log does not say why nothing happened:\n%s", joined)
	}
}

// TestRenewReplacesWhatIsDue runs the nightly pass over a certificate that is
// close to expiry: the pair has to be replaced, the private key kept, and the
// account not registered a second time.
func TestRenewReplacesWhatIsDue(t *testing.T) {
	srv := newACMEServer(t)
	rec, _ := useFakeCA(t, srv)
	srv.setLeafDays(10)
	domain := "dev.example.com"

	var lines []string
	if err := Issue(context.Background(), domain, "me@example.com", collect(&lines)); err != nil {
		t.Fatalf("Issue: %v", err)
	}
	before, err := expiryOf(domain)
	if err != nil {
		t.Fatal(err)
	}
	_, keyPath, _ := Paths(domain)
	fullchainPath := filepath.Join(filepath.Dir(keyPath), fullchainName)
	keyBefore, err := os.ReadFile(keyPath)
	if err != nil {
		t.Fatal(err)
	}
	certBefore, err := os.ReadFile(fullchainPath)
	if err != nil {
		t.Fatal(err)
	}
	presentedBefore := len(rec.presented)

	renewed, err := Renew(context.Background(), collect(&lines))
	if err != nil {
		t.Fatalf("Renew: %v\nlog:\n%s", err, strings.Join(lines, "\n"))
	}
	if len(renewed) != 1 || renewed[0] != domain {
		t.Fatalf("renewed = %v, want [%s]", renewed, domain)
	}
	// A renewal replaces the certificate, not the key: the pair that is served has
	// to keep its key pair, and the certificate has to be a new one.
	certAfter, err := os.ReadFile(fullchainPath)
	if err != nil {
		t.Fatal(err)
	}
	if string(certAfter) == string(certBefore) {
		t.Error("the certificate on disk was not replaced")
	}
	if got := srv.issueCount(); got != 2 {
		t.Errorf("the CA signed %d certificates, want 2", got)
	}
	after, err := expiryOf(domain)
	if err != nil {
		t.Fatal(err)
	}
	if after.Before(before) {
		t.Errorf("the renewed certificate expires earlier: %s -> %s", before, after)
	}
	keyAfter, err := os.ReadFile(keyPath)
	if err != nil {
		t.Fatal(err)
	}
	if string(keyAfter) != string(keyBefore) {
		t.Error("the renewal replaced the private key as well")
	}
	if _, err := tls.LoadX509KeyPair(fullchainPath, keyPath); err != nil {
		t.Errorf("the renewed pair does not load: %v", err)
	}
	if len(rec.presented) != presentedBefore+1 {
		t.Errorf("the renewal presented %d challenges, want 1", len(rec.presented)-presentedBefore)
	}
	if got := srv.accountCount(); got != 1 {
		t.Errorf("registration requests = %d, want 1: the account exists", got)
	}
	if joined := strings.Join(lines, "\n"); !strings.Contains(joined, "renewed "+domain) {
		t.Errorf("the log does not report the renewal:\n%s", joined)
	}
}

// TestRenewSkipsWhatIsFresh keeps the nightly timer off the CA: a certificate with
// more than RenewBefore left is not renewed, and the services are then not
// restarted either.
func TestRenewSkipsWhatIsFresh(t *testing.T) {
	srv := newACMEServer(t)
	dir := tempDir(t)
	writePair(t, dir, "example.com", time.Now().AddDate(0, 0, 60))
	registerAccount(t, dir, srv.url("/account/1"))
	directoryFor = func(bool) string {
		t.Error("a certificate that is not due must not cost a request")
		return srv.url("/directory")
	}
	t.Cleanup(func() { directoryFor = letsEncryptDirectory })

	var lines []string
	renewed, err := Renew(context.Background(), collect(&lines))
	if err != nil {
		t.Fatalf("Renew: %v", err)
	}
	if len(renewed) != 0 {
		t.Fatalf("renewed = %v, want none", renewed)
	}
	if got := srv.requestCount(); got != 0 {
		t.Errorf("the CA was contacted %d times", got)
	}
	if joined := strings.Join(lines, "\n"); !strings.Contains(joined, "not due") {
		t.Errorf("the log does not say why nothing happened:\n%s", joined)
	}
}

func TestRenewWithoutAnythingToDo(t *testing.T) {
	tempDir(t)
	renewed, err := Renew(context.Background(), func(string) {})
	if err != nil {
		t.Fatalf("a panel with no certificates has nothing to renew: %v", err)
	}
	if len(renewed) != 0 {
		t.Fatalf("renewed = %v, want none", renewed)
	}
}

// TestRenewWithoutAnAccount covers the state a panel is in between losing its
// state directory and issuing again: there are certificates, but nothing to sign a
// renewal with, and the operator has to be told rather than left with a silent
// night of nothing.
func TestRenewWithoutAnAccount(t *testing.T) {
	dir := tempDir(t)
	writePair(t, dir, "example.com", time.Now().AddDate(0, 0, 10))

	_, err := Renew(context.Background(), func(string) {})
	if err == nil {
		t.Fatal("renewing without an account should fail")
	}
	if !strings.Contains(err.Error(), "account") {
		t.Errorf("the error does not name the missing account: %v", err)
	}
}

func TestEnsureAccountRegistersOnce(t *testing.T) {
	srv := newACMEServer(t)
	useFakeCA(t, srv)

	if err := EnsureAccount(context.Background(), "me@example.com", func(string) {}); err != nil {
		t.Fatalf("EnsureAccount: %v", err)
	}
	if !Registered() {
		t.Fatal("the account was not stored")
	}
	// The second call is the one the issue flow makes on every run: it must not
	// cost a request.
	before := srv.requestCount()
	if err := EnsureAccount(context.Background(), "me@example.com", func(string) {}); err != nil {
		t.Fatalf("EnsureAccount: %v", err)
	}
	if got := srv.requestCount(); got != before {
		t.Errorf("the second call made %d requests, want none", got-before)
	}
	if got := srv.accountCount(); got != 1 {
		t.Errorf("registration requests = %d, want 1", got)
	}
}

// TestEnsureAccountNeedsAnAddress is the one thing that cannot be defaulted: the
// CA uses the address to warn about an expiring certificate, and a registration
// without one is not worth making.
func TestEnsureAccountNeedsAnAddress(t *testing.T) {
	srv := newACMEServer(t)
	useFakeCA(t, srv)

	err := EnsureAccount(context.Background(), "   ", func(string) {})
	if err == nil {
		t.Fatal("registering without an address should fail")
	}
	if got := srv.requestCount(); got != 0 {
		t.Errorf("the CA was contacted %d times without an address", got)
	}
}

// TestBrokenAccountStateIsReported covers the file an operator may have edited or
// a disk may have truncated: re-registering over it would silently adopt a new
// account, so the failure has to surface.
func TestBrokenAccountStateIsReported(t *testing.T) {
	srv := newACMEServer(t)
	_, dir := useFakeCA(t, srv)
	registerAccount(t, dir, srv.url("/account/1"))
	if err := os.WriteFile(filepath.Join(dir, accountJSONName), []byte("{"), 0o600); err != nil {
		t.Fatal(err)
	}
	if Registered() {
		t.Error("an account file that cannot be parsed is not a registration")
	}
	err := EnsureAccount(context.Background(), "me@example.com", func(string) {})
	if err == nil {
		t.Fatal("a broken account file should be reported")
	}
	if !strings.Contains(err.Error(), accountJSONName) {
		t.Errorf("the error does not name the file: %v", err)
	}
}

// TestIssueRejectsWhatIsNotADomain keeps a value that would become half a path out
// of the state directory, before any of it is written.
func TestIssueRejectsWhatIsNotADomain(t *testing.T) {
	tempDir(t)
	for _, domain := range []string{"", "  ", "../../etc/passwd", "a/b"} {
		if err := Issue(context.Background(), domain, "me@example.com", func(string) {}); err == nil {
			t.Errorf("Issue(%q) should have failed", domain)
		}
	}
}
