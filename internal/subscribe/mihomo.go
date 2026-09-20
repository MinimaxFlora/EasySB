package subscribe

import (
	_ "embed"
	"fmt"
	"strings"
	"text/template"

	"github.com/MinimaxFlora/EasySB/internal/state"
)

//go:embed mihomo.yaml
var mihomoTemplate string

var mihomoTpl = template.Must(template.New("mihomo").Parse(mihomoTemplate))

// mihomoLabels maps a client template tag to the display name used in the
// generated profile.
var mihomoLabels = map[string]string{
	"anytls":               "AnyTLS",
	"hysteria2":            "Hysteria2",
	"tuic":                 "TUIC",
	"vmess-ws-tls":         "VMess-WS-TLS",
	"vless-vision-reality": "VLESS-Reality",
}

// GenerateMihomo renders a complete mihomo / Clash Meta profile from the state.
func GenerateMihomo(cfg state.Config) ([]byte, error) {
	if cfg.Host() == "" {
		return nil, fmt.Errorf("no server address")
	}
	if cfg.UUID == "" {
		return nil, fmt.Errorf("no uuid")
	}
	enabled := EnabledTags(cfg)
	if len(enabled) == 0 {
		return nil, fmt.Errorf("no protocol enabled")
	}
	hop := cfg.HopRange
	if hop == "" {
		hop = state.DefaultHopRange
	}
	rsni := cfg.RealitySNI
	if rsni == "" {
		rsni = state.DefaultSNI
	}

	var proxies, nodes strings.Builder
	for _, tag := range enabled {
		name, block := mihomoProxy(tag, cfg, hop, rsni)
		if block == "" {
			continue
		}
		proxies.WriteString(block)
		nodes.WriteString("      - " + yamlString(name) + "\n")
	}

	var out strings.Builder
	if err := mihomoTpl.Execute(&out, map[string]string{
		"Proxies": proxies.String(),
		"Nodes":   nodes.String(),
	}); err != nil {
		return nil, err
	}
	return []byte(out.String()), nil
}

// mihomoProxy renders one proxy entry and returns its name and YAML block.
func mihomoProxy(tag string, cfg state.Config, hop, rsni string) (string, string) {
	host := cfg.Host()
	name := "EasySB-" + mihomoLabels[tag]
	var b strings.Builder

	switch tag {
	case "anytls":
		fmt.Fprintf(&b, "  - name: %s\n", yamlString(name))
		b.WriteString("    type: anytls\n")
		yamlKV(&b, "server", host)
		yamlInt(&b, "port", portInt(cfg, state.ProtoAnyTLS))
		yamlKV(&b, "password", cfg.Password)
		yamlKV(&b, "sni", host)
		b.WriteString("    skip-cert-verify: false\n")
		b.WriteString("    udp: true\n")
	case "hysteria2":
		fmt.Fprintf(&b, "  - name: %s\n", yamlString(name))
		b.WriteString("    type: hysteria2\n")
		yamlKV(&b, "server", host)
		yamlInt(&b, "port", portInt(cfg, state.ProtoHysteria2))
		yamlKV(&b, "ports", strings.ReplaceAll(hop, ":", "-"))
		yamlKV(&b, "password", cfg.Password)
		yamlKV(&b, "sni", host)
		b.WriteString("    skip-cert-verify: false\n")
		b.WriteString("    alpn:\n      - h3\n")
	case "tuic":
		fmt.Fprintf(&b, "  - name: %s\n", yamlString(name))
		b.WriteString("    type: tuic\n")
		yamlKV(&b, "server", host)
		yamlInt(&b, "port", portInt(cfg, state.ProtoTUIC))
		yamlKV(&b, "uuid", cfg.UUID)
		yamlKV(&b, "password", cfg.Password)
		b.WriteString("    congestion-controller: bbr\n")
		b.WriteString("    udp-relay-mode: native\n")
		yamlKV(&b, "sni", host)
		b.WriteString("    alpn:\n      - h3\n")
		b.WriteString("    skip-cert-verify: false\n")
	case "vmess-ws-tls":
		fmt.Fprintf(&b, "  - name: %s\n", yamlString(name))
		b.WriteString("    type: vmess\n")
		yamlKV(&b, "server", host)
		yamlInt(&b, "port", portInt(cfg, state.ProtoVMessWSTLS))
		yamlKV(&b, "uuid", cfg.UUID)
		b.WriteString("    alterId: 0\n")
		b.WriteString("    cipher: auto\n")
		b.WriteString("    udp: true\n")
		b.WriteString("    tls: true\n")
		b.WriteString("    skip-cert-verify: false\n")
		yamlKV(&b, "servername", host)
		b.WriteString("    network: ws\n")
		b.WriteString("    ws-opts:\n")
		b.WriteString("      path: /vmess\n")
		b.WriteString("      headers:\n")
		fmt.Fprintf(&b, "        Host: %s\n", yamlString(host))
	case "vless-vision-reality":
		fmt.Fprintf(&b, "  - name: %s\n", yamlString(name))
		b.WriteString("    type: vless\n")
		yamlKV(&b, "server", host)
		yamlInt(&b, "port", portInt(cfg, state.ProtoVLESSReality))
		yamlKV(&b, "uuid", cfg.UUID)
		b.WriteString("    network: tcp\n")
		b.WriteString("    udp: true\n")
		b.WriteString("    tls: true\n")
		b.WriteString("    flow: xtls-rprx-vision\n")
		yamlKV(&b, "servername", rsni)
		b.WriteString("    client-fingerprint: chrome\n")
		b.WriteString("    reality-opts:\n")
		yamlKVIndent(&b, "      ", "public-key", cfg.RealityPub)
		yamlKVIndent(&b, "      ", "short-id", cfg.RealitySID)
	default:
		return "", ""
	}
	return name, b.String()
}

func yamlKV(b *strings.Builder, key, value string) {
	yamlKVIndent(b, "    ", key, value)
}

func yamlKVIndent(b *strings.Builder, indent, key, value string) {
	fmt.Fprintf(b, "%s%s: %s\n", indent, key, yamlString(value))
}

func yamlInt(b *strings.Builder, key string, value int) {
	fmt.Fprintf(b, "    %s: %d\n", key, value)
}

// yamlString double-quotes a scalar and escapes it so node names and
// credentials can never break the document.
func yamlString(s string) string {
	s = strings.ReplaceAll(s, "\\", "\\\\")
	s = strings.ReplaceAll(s, "\"", "\\\"")
	return "\"" + s + "\""
}
