package deploy

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/MinimaxFlora/EasySB/internal/cert"
	"github.com/MinimaxFlora/EasySB/internal/sbcore"
	"github.com/MinimaxFlora/EasySB/internal/state"
	"github.com/MinimaxFlora/EasySB/internal/user"
)

// testAccount returns one account that selected every protocol, with credentials.
func testAccount(t *testing.T) user.User {
	t.Helper()
	account := user.New("alice", state.Keys, time.Now())
	account.EnsureCredentials()
	if account.Token == "" {
		t.Fatal("the test account has no token: the stats user list is keyed by it")
	}
	return account
}

// installTestCertificate puts a certificate pair for the domain where cert.Paths looks
// for it, so rendering a configuration needs no ACME account and touches nothing outside
// the temporary certificate directory.
func installTestCertificate(t *testing.T, dir, domain string) {
	t.Helper()
	t.Setenv(cert.DirEnv, dir)
	pairDir := filepath.Join(dir, domain)
	if err := os.MkdirAll(pairDir, 0o755); err != nil {
		t.Fatalf("create certificate dir: %v", err)
	}
	if err := cert.GenerateSelfSigned(filepath.Join(pairDir, "fullchain.cer"), filepath.Join(pairDir, "private.key"), domain); err != nil {
		t.Fatalf("generate self-signed pair: %v", err)
	}
}

// taggedProtocols are the protocols whose code sits behind a build tag: Hysteria2 and
// TUIC need with_quic, and the Reality inbound needs with_utls. The release tag set
// (release/TAGS) carries both, so their documents are checked in
// deploy_release_test.go; the tests here run in every build.
func taggedProtocols() map[string]bool {
	return map[string]bool{
		state.ProtoAnyTLS:     true,
		state.ProtoVMessWSTLS: true,
	}
}

// TestGeneratedConfigIsAcceptedByTheCarriedCore is the acceptance test for the whole
// arrangement: the document the panel renders has to be accepted by the core compiled
// into this binary. There is no second core to fall back on and no sing-box in PATH — a
// document this engine refuses is a node that never starts, and the panel would only
// find out from the service's journal.
func TestGeneratedConfigIsAcceptedByTheCarriedCore(t *testing.T) {
	const domain = "example.com"
	installTestCertificate(t, t.TempDir(), domain)

	cfg := state.Default()
	cfg.Domain = domain
	cfg.Enabled = taggedProtocols()

	account := testAccount(t)
	document, err := ServerConfig(cfg, []user.User{account})
	if err != nil {
		t.Fatalf("ServerConfig: %v", err)
	}
	path := filepath.Join(t.TempDir(), "config.json")
	if err := os.WriteFile(path, document, 0o644); err != nil {
		t.Fatalf("write config: %v", err)
	}
	if err := sbcore.Check(context.Background(), path); err != nil {
		t.Fatalf("the carried core refused the generated config: %v\n%s", err, document)
	}

	// The counters block follows the build, not the host: a core without the V2Ray API
	// rejects the whole document, so its presence has to track StatsCapable exactly.
	carries := strings.Contains(string(document), `"v2ray_api"`)
	if carries != sbcore.StatsCapable() {
		t.Fatalf("config carries v2ray_api = %v, but this build counts traffic = %v", carries, sbcore.StatsCapable())
	}
	if carries && !strings.Contains(string(document), account.Token) {
		t.Fatal("the stats user list must name the account token, or usage is never counted")
	}
}

// TestServerConfigNeedsNoCoreOnDisk pins the property that replaced the old "is the core
// installed" gate: rendering a configuration depends on the accounts, the state and the
// certificate, and on nothing on the host.
func TestServerConfigNeedsNoCoreOnDisk(t *testing.T) {
	const domain = "example.com"
	installTestCertificate(t, t.TempDir(), domain)

	cfg := state.Default()
	cfg.Domain = domain
	cfg.Enabled = taggedProtocols()
	document, err := ServerConfig(cfg, nil)
	if err != nil {
		t.Fatalf("ServerConfig with no accounts: %v", err)
	}
	if len(document) == 0 {
		t.Fatal("no document rendered")
	}
	// A node without accounts is legal and starts; only the listener that carries them
	// needs a member to be there at all.
	path := filepath.Join(t.TempDir(), "config.json")
	if err := os.WriteFile(path, document, 0o644); err != nil {
		t.Fatalf("write config: %v", err)
	}
	if err := sbcore.Check(context.Background(), path); err != nil {
		t.Fatalf("the carried core refused a node with no accounts: %v\n%s", err, document)
	}
}

// TestServerConfigRefusesRealityWithoutKeypair keeps the renderer from producing a
// document the core rejects as a whole: sing-box refuses a Reality inbound whose private
// key is empty, and an error naming the missing keypair is more use than the core's own
// message arriving from the service's journal. This one asks the renderer only, so it
// holds in a build without the Reality tag too.
func TestServerConfigRefusesRealityWithoutKeypair(t *testing.T) {
	const domain = "example.com"
	installTestCertificate(t, t.TempDir(), domain)

	cfg := state.Default()
	cfg.Domain = domain
	cfg.Enabled = map[string]bool{state.ProtoVLESSReality: true}
	cfg.RealityPriv, cfg.RealityPub = "", ""
	if _, err := ServerConfig(cfg, nil); !errors.Is(err, ErrNoRealityKey) {
		t.Fatalf("ServerConfig without a keypair = %v, want %v", err, ErrNoRealityKey)
	}
}
