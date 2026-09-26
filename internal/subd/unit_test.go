package subd

import (
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/MinimaxFlora/EasySB/internal/service"
	"github.com/MinimaxFlora/EasySB/internal/sysinfo"
)

// The subscription unit runs this same binary with --serve, and it has to name the
// installed panel rather than a scratch copy: a unit rewritten to a copy that is then
// deleted takes every client's subscription down with it.
func TestSubscriptionUnitRunsThePanel(t *testing.T) {
	path := filepath.Join(t.TempDir(), "easysb.service")
	if err := writeUnit(path, "/usr/local/bin/easysb", service.Systemd); err != nil {
		t.Fatalf("writeUnit: %v", err)
	}
	body, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("read back: %v", err)
	}
	text := string(body)
	if !strings.Contains(text, "ExecStart=/usr/local/bin/easysb --serve") {
		t.Fatalf("the unit does not serve subscriptions from the installed panel:\n%s", text)
	}
	// The endpoint is what every client's subscription URL points at, so the unit has to
	// survive a reboot of the node it depends on.
	if !strings.Contains(text, "Restart=always") {
		t.Fatalf("the endpoint unit should restart on failure:\n%s", text)
	}
	if !strings.Contains(text, "Wants="+sysinfo.ServiceName+".service") {
		t.Fatalf("the endpoint should be started with the node:\n%s", text)
	}
}

// The OpenRC form is written with a different shape, so it is checked on its own rather
// than assumed to follow from the systemd one.
func TestSubscriptionOpenRCUnit(t *testing.T) {
	path := filepath.Join(t.TempDir(), "easysb")
	if err := writeUnit(path, "/usr/local/bin/easysb", service.OpenRC); err != nil {
		t.Fatalf("writeUnit: %v", err)
	}
	body, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("read back: %v", err)
	}
	text := string(body)
	if !strings.Contains(text, `command="/usr/local/bin/easysb"`) ||
		!strings.Contains(text, `command_args="--serve"`) {
		t.Fatalf("the OpenRC unit does not serve subscriptions:\n%s", text)
	}
}
