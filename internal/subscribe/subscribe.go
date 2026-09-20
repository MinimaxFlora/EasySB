// Package subscribe builds client subscription URLs, per-protocol share links
// and QR payloads from the persisted node state.
package subscribe

import (
	"encoding/base64"
	"encoding/json"
	"fmt"
	"net/url"
	"os"
	"os/exec"
	"path/filepath"
	"strings"

	"github.com/MinimaxFlora/EasySB/internal/state"
)

// ImportScheme is the sing-box client deep link used to import a remote profile.
// A bare subscription URL is not recognised by the client, which is what broke
// QR scanning in the legacy build.
const ImportScheme = "sing-box://import-remote-profile?url="

// URL returns the subscription endpoint derived from the state.
func URL(cfg state.Config) string {
	host := cfg.Host()
	scheme := "http"
	if cfg.Domain != "" && certExists(cfg.Domain) {
		scheme = "https"
	}
	port := cfg.SubPort
	if port == "" {
		port = state.DefaultSubPort
	}
	path := cfg.SubPath
	if path == "" {
		path = state.DefaultSubPath
	}
	if !strings.HasPrefix(path, "/") {
		path = "/" + path
	}
	return fmt.Sprintf("%s://%s:%s%s", scheme, host, port, path)
}

// DeepLink wraps a subscription URL into the sing-box import deep link.
func DeepLink(subURL string) string {
	return ImportScheme + url.QueryEscape(subURL)
}

// ShareLinks returns the enabled protocols' share links in canonical order.
func ShareLinks(cfg state.Config) []string {
	host := cfg.Host()
	name := "EasySB"
	var links []string

	if cfg.Enabled[state.ProtoAnyTLS] {
		links = append(links, fmt.Sprintf("anytls://%s@%s:%s?insecure=0&sni=%s#%s-AnyTLS",
			cfg.Password, host, cfg.Ports[state.ProtoAnyTLS], host, name))
	}
	if cfg.Enabled[state.ProtoHysteria2] {
		links = append(links, fmt.Sprintf("hysteria2://%s@%s:%s?sni=%s&insecure=0#%s-Hysteria2",
			cfg.Password, host, cfg.Ports[state.ProtoHysteria2], host, name))
		if cfg.HopRange != "" {
			links = append(links, "# Hysteria2 port hopping: "+cfg.HopRange)
		}
	}
	if cfg.Enabled[state.ProtoTUIC] {
		links = append(links, fmt.Sprintf("tuic://%s:%s@%s:%s?congestion_control=bbr&alpn=h3&sni=%s&udp_relay_mode=native#%s-TUIC",
			cfg.UUID, cfg.Password, host, cfg.Ports[state.ProtoTUIC], host, name))
	}
	if cfg.Enabled[state.ProtoVMessWSTLS] {
		links = append(links, vmessLink(cfg, host, name))
	}
	if cfg.Enabled[state.ProtoVLESSReality] {
		sni := cfg.RealitySNI
		if sni == "" {
			sni = state.DefaultSNI
		}
		links = append(links, fmt.Sprintf("vless://%s@%s:%s?encryption=none&flow=xtls-rprx-vision&security=reality&sni=%s&fp=chrome&pbk=%s&sid=%s&type=tcp#%s-VLESS-Reality",
			cfg.UUID, host, cfg.Ports[state.ProtoVLESSReality], sni, cfg.RealityPub, cfg.RealitySID, name))
	}
	return links
}

func vmessLink(cfg state.Config, host, name string) string {
	sni := host
	payload := map[string]any{
		"v":    "2",
		"ps":   name + "-VMess",
		"add":  host,
		"port": cfg.Ports[state.ProtoVMessWSTLS],
		"id":   cfg.UUID,
		"aid":  "0",
		"scy":  "auto",
		"net":  "ws",
		"type": "none",
		"host": sni,
		"path": "/vmess",
		"tls":  "tls",
		"sni":  sni,
	}
	raw, err := json.Marshal(payload)
	if err != nil {
		return ""
	}
	return "vmess://" + base64.StdEncoding.EncodeToString(raw)
}

// QRCode renders payload as a terminal QR block art using qrencode.
func QRCode(payload string) (string, error) {
	path, err := exec.LookPath("qrencode")
	if err != nil {
		return "", fmt.Errorf("qrencode not installed")
	}
	out, err := exec.Command(path, "-t", "UTF8", payload).CombinedOutput()
	if err != nil {
		return "", fmt.Errorf("qrencode: %w", err)
	}
	return strings.TrimRight(string(out), "\n"), nil
}

// certExists reports whether an active certificate is available for domain.
func certExists(domain string) bool {
	home, err := os.UserHomeDir()
	if err != nil {
		home = "/root"
	}
	candidates := []string{
		filepath.Join(home, ".acme.sh", domain+"_ecc", "fullchain.cer"),
		filepath.Join(home, ".acme.sh", domain, "fullchain.cer"),
	}
	for _, c := range candidates {
		if fi, err := os.Stat(c); err == nil && !fi.IsDir() && fi.Size() > 0 {
			return true
		}
	}
	return false
}
