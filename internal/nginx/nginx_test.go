package nginx

import (
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/MinimaxFlora/EasySB/internal/state"
)

func TestWriteSiteHTTP(t *testing.T) {
	dir := t.TempDir()
	t.Setenv("EASYSB_NGINX_CONF_DIR", dir)

	cfg := state.Default()
	cfg.ServerIP = "203.0.113.10"

	// WriteSite validates with `nginx -t` and restarts nginx; without nginx
	// installed that would fail, so exercise the renderer directly.
	conf, err := renderSite(cfg)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(ConfPath(), []byte(conf), 0o644); err != nil {
		t.Fatal(err)
	}
	data, err := os.ReadFile(filepath.Join(dir, ConfName))
	if err != nil {
		t.Fatal(err)
	}
	body := string(data)
	if !strings.Contains(body, "listen "+state.DefaultSubPort+";") {
		t.Fatalf("http listen missing: %s", body)
	}
	if !strings.Contains(body, "server_name _;") {
		t.Fatalf("expected catch-all server_name: %s", body)
	}
	if !strings.Contains(body, "location "+state.DefaultSubPath) {
		t.Fatalf("subscription location missing: %s", body)
	}
	if strings.Contains(body, "ssl") {
		t.Fatalf("http site should not enable ssl: %s", body)
	}
}

func TestRenderSiteClientLocations(t *testing.T) {
	cfg := state.Default()
	cfg.ServerIP = "203.0.113.10"
	cfg.UUID = "11111111-2222-3333-4444-555555555555"

	conf, err := renderSite(cfg)
	if err != nil {
		t.Fatal(err)
	}
	for _, want := range []string{
		"location = /singbox/" + cfg.UUID,
		"location = /mihomo/" + cfg.UUID,
		"location = /v2ray/" + cfg.UUID,
		"mihomo.yaml",
		"v2ray.txt",
		`default_type "text/yaml; charset=utf-8";`,
		`default_type "text/plain; charset=utf-8";`,
	} {
		if !strings.Contains(conf, want) {
			t.Fatalf("site missing %q:\n%s", want, conf)
		}
	}
}
