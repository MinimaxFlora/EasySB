package core

import (
	"context"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/MinimaxFlora/EasySB/internal/cert"
	"github.com/MinimaxFlora/EasySB/internal/config"
	"github.com/MinimaxFlora/EasySB/internal/sbcore"
	"github.com/MinimaxFlora/EasySB/internal/state"
	"github.com/MinimaxFlora/EasySB/internal/user"
)

// renderServerConfig renders the panel's own five-protocol config, the way the deploy
// path does, with a self-signed certificate and a Reality keypair this binary generated.
func renderServerConfig(t *testing.T) []byte {
	t.Helper()
	dir := t.TempDir()
	priv, pub, err := sbcore.RealityKeypair()
	if err != nil {
		t.Fatalf("RealityKeypair: %v", err)
	}
	if priv == "" || pub == "" {
		t.Fatal("RealityKeypair returned an empty key")
	}
	certPath := filepath.Join(dir, "fullchain.cer")
	keyPath := filepath.Join(dir, "private.key")
	if err := cert.GenerateSelfSigned(certPath, keyPath, "easysb.local"); err != nil {
		t.Fatalf("GenerateSelfSigned: %v", err)
	}

	params := config.Params{
		Enabled:       map[string]bool{},
		Ports:         map[string]string{},
		RealitySNI:    "apple.com",
		RealityPriv:   priv,
		RealitySID:    "abcd1234",
		CertFullchain: certPath,
		CertKey:       keyPath,
		Stats:         sbcore.StatsAvailable(),
	}
	for _, key := range state.Keys {
		params.Enabled[key] = true
	}
	// The account comes from the store, the way the deploy path renders it: the store fills
	// only the fields each protocol authenticates with, and a field a protocol does not have
	// (a uuid on an AnyTLS user) is an unknown field the core refuses whole.
	account := user.New("test-account", state.Keys, time.Now())
	account.EnsureCredentials()
	params.Members = config.MembersFrom([]user.User{account})

	data, err := config.Build(params)
	if err != nil {
		t.Fatalf("config.Build: %v", err)
	}
	return data
}

// The core is inside this binary, so the panel's own config has to be accepted by it in
// process: this is the check the deploy path runs before it starts the node.
func TestCheckAcceptsGeneratedConfig(t *testing.T) {
	if !sbcore.StatsAvailable() {
		// The five-protocol config needs the QUIC inbounds and the V2Ray API, which only
		// the release tag set brings; a dev build refuses it (correctly). CI runs this
		// both with and without those tags, so the acceptance half is covered there.
		t.Skip("build without the release tags")
	}
	data := renderServerConfig(t)
	path := filepath.Join(t.TempDir(), "config.json")
	if err := os.WriteFile(path, data, 0o644); err != nil {
		t.Fatal(err)
	}

	if err := sbcore.Check(path); err != nil {
		t.Fatalf("sbcore.Check: %v", err)
	}
	// The rendered config and the build have to agree in both directions: a config naming
	// an API this binary was not built with is rejected whole, and a binary that can count
	// traffic needs the block to count anything. CI runs this both with and without the
	// release tags, so both halves are covered.
	carries := strings.Contains(string(data), "v2ray_api")
	if carries != SupportsV2RayStats(context.Background()) {
		t.Fatalf("config carries v2ray_api = %v, build can count traffic = %v", carries, SupportsV2RayStats(context.Background()))
	}
}

// A config this build cannot express must be refused, which is what makes the check
// worth running before the service starts.
func TestCheckRejectsBrokenConfig(t *testing.T) {
	path := filepath.Join(t.TempDir(), "config.json")
	broken := `{"inbounds":[{"type":"no-such-inbound","tag":"x"}]}`
	if err := os.WriteFile(path, []byte(broken), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := sbcore.Check(path); err == nil {
		t.Fatal("sbcore.Check accepted a config naming an inbound this build does not have")
	}
	if ConfigCheck(context.Background(), path) {
		t.Fatal("ConfigCheck accepted a config naming an inbound this build does not have")
	}
}

// The version is what the panel shows on every page, so it has to be readable in a test
// build as well as in a release build.
func TestVersionIsReadable(t *testing.T) {
	v := sbcore.Version()
	if v == "" || v == "unknown" {
		t.Fatalf("Version() = %q; a build has to name the sing-box it carries", v)
	}
	if LocalVersion(context.Background()) != v {
		t.Fatalf("LocalVersion = %q, want %q", LocalVersion(context.Background()), v)
	}
	if !Installed() {
		t.Fatal("Installed() must be true: the core is this binary")
	}
}
