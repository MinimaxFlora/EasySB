package subscribe

import (
	"strings"
	"testing"

	"github.com/MinimaxFlora/EasySB/internal/state"
)

func TestGenerateMihomo(t *testing.T) {
	cfg := testConfig()
	cfg.Enabled[state.ProtoTUIC] = false
	cfg.Enabled[state.ProtoAnyTLS] = false

	data, err := GenerateMihomo(cfg)
	if err != nil {
		t.Fatal(err)
	}
	body := string(data)
	for _, want := range []string{
		"mixed-port: 7890",
		"proxy-groups:",
		"type: hysteria2",
		"type: vmess",
		"type: vless",
		"reality-opts:",
		`"apple.com"`,
		"GEOIP,CN,DIRECT",
	} {
		if !strings.Contains(body, want) {
			t.Fatalf("mihomo config missing %q:\n%s", want, body)
		}
	}
	if strings.Contains(body, "type: tuic") || strings.Contains(body, "type: anytls") {
		t.Fatalf("disabled protocols leaked into mihomo config:\n%s", body)
	}
}

func TestGenerateMihomoRequiresHost(t *testing.T) {
	cfg := testConfig()
	cfg.Domain = ""
	cfg.ServerIP = ""
	if _, err := GenerateMihomo(cfg); err == nil {
		t.Fatal("expected error without a server address")
	}
}

// TestGenerateMihomoTemplateActionsNotInComments guards against reintroducing
// template actions inside YAML comments, which would inject proxy entries above
// the document root and make the profile unparseable.
func TestGenerateMihomoTemplateActionsNotInComments(t *testing.T) {
	cfg := testConfig()
	data, err := GenerateMihomo(cfg)
	if err != nil {
		t.Fatal(err)
	}
	inProxies := false
	for _, line := range strings.Split(string(data), "\n") {
		trimmed := strings.TrimSpace(line)
		if trimmed == "proxies:" {
			inProxies = true
			continue
		}
		if inProxies || trimmed == "" || strings.HasPrefix(trimmed, "#") {
			continue
		}
		if strings.HasPrefix(trimmed, "type:") {
			t.Fatalf("proxy entry leaked before the proxies: key: %q", line)
		}
	}
}
