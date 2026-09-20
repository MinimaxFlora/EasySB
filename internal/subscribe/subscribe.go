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

// Client identifies one subscription format served by nginx.
type Client string

const (
	// ClientSingBox serves the JSON profile consumed by sing-box (SFM/SFA/SFI).
	ClientSingBox Client = "singbox"
	// ClientMihomo serves a complete mihomo / Clash Meta YAML profile.
	ClientMihomo Client = "mihomo"
	// ClientV2Ray serves the base64 share-link document imported by v2rayN and
	// similar clients.
	ClientV2Ray Client = "v2ray"
)

// Clients lists the supported subscription formats in menu order.
var Clients = []Client{ClientSingBox, ClientMihomo, ClientV2Ray}

// ImportScheme is the sing-box client deep link used to import a remote profile.
// A bare subscription URL is not recognised by the client, which is what broke
// QR scanning in the legacy build.
const ImportScheme = "sing-box://import-remote-profile?url="

// ClashImportScheme is the deep link used by Clash / mihomo clients to import a
// remote profile.
const ClashImportScheme = "clash://install-config?url="

// URL returns the legacy subscription endpoint derived from the state.
func URL(cfg state.Config) string {
	path := cfg.SubPath
	if path == "" {
		path = state.DefaultSubPath
	}
	if !strings.HasPrefix(path, "/") {
		path = "/" + path
	}
	return baseURL(cfg) + path
}

// ClientPath returns the URL path served for one client format. The node UUID
// acts as the access token so the document is not publicly guessable.
func ClientPath(cfg state.Config, client Client) string {
	return fmt.Sprintf("/%s/%s", client, cfg.UUID)
}

// ClientURL returns the subscription endpoint for one client format. The node
// UUID acts as the access token: <scheme>://host:port/<client>/<uuid>.
func ClientURL(cfg state.Config, client Client) string {
	return baseURL(cfg) + ClientPath(cfg, client)
}

// ClientFile returns the generated file name backing a client endpoint. The
// sing-box profile keeps the legacy name so the old /subscribe path still
// works.
func ClientFile(client Client) string {
	switch client {
	case ClientMihomo:
		return "mihomo.yaml"
	case ClientV2Ray:
		return "v2ray.txt"
	default:
		return "subscribe.json"
	}
}

// ClientLink wraps a client subscription URL into the deep link the client
// understands. v2rayN imports the plain URL, so it is returned unchanged.
func ClientLink(cfg state.Config, client Client) string {
	u := ClientURL(cfg, client)
	switch client {
	case ClientSingBox:
		return DeepLink(u)
	case ClientMihomo:
		return ClashImportScheme + url.QueryEscape(u)
	default:
		return u
	}
}

// baseURL returns scheme://host:port for subscription links.
func baseURL(cfg state.Config) string {
	host := cfg.Host()
	scheme := "http"
	if cfg.Domain != "" && certExists(cfg.Domain) {
		scheme = "https"
	}
	port := cfg.SubPort
	if port == "" {
		port = state.DefaultSubPort
	}
	return fmt.Sprintf("%s://%s:%s", scheme, host, port)
}

// DeepLink wraps a subscription URL into the sing-box import deep link.
func DeepLink(subURL string) string {
	return ImportScheme + url.QueryEscape(subURL)
}

// ShareLinks returns the enabled protocols' share links in canonical order.
// Every URI follows the de-facto scheme each client parses, so the same link
// works in sing-box, mihomo, v2rayN and friends.
func ShareLinks(cfg state.Config) []string {
	host := cfg.Host()
	name := "EasySB"
	var links []string

	if cfg.Enabled[state.ProtoAnyTLS] {
		links = append(links, anytlsLink(cfg, host, name))
	}
	if cfg.Enabled[state.ProtoHysteria2] {
		links = append(links, hysteria2Link(cfg, host, name))
	}
	if cfg.Enabled[state.ProtoTUIC] {
		links = append(links, tuicLink(cfg, host, name))
	}
	if cfg.Enabled[state.ProtoVMessWSTLS] {
		links = append(links, vmessLink(cfg, host, name))
	}
	if cfg.Enabled[state.ProtoVLESSReality] {
		links = append(links, vlessLink(cfg, host, name))
	}
	return links
}

// V2RaySubscription encodes the share links as one base64 document, the
// subscription format v2rayN and similar clients import.
func V2RaySubscription(cfg state.Config) string {
	raw := strings.Join(ShareLinks(cfg), "\n") + "\n"
	return base64.StdEncoding.EncodeToString([]byte(raw))
}

func anytlsLink(cfg state.Config, host, name string) string {
	q := url.Values{}
	q.Set("sni", host)
	q.Set("insecure", "0")
	port := portOf(cfg, state.ProtoAnyTLS)
	// The trailing slash before the query is required by the AnyTLS URI spec;
	// omitting it makes clients reject the link.
	return fmt.Sprintf("anytls://%s@%s:%s/?%s#%s-AnyTLS",
		url.User(cfg.Password).String(), host, port, q.Encode(), name)
}

func hysteria2Link(cfg state.Config, host, name string) string {
	q := url.Values{}
	q.Set("sni", host)
	q.Set("insecure", "0")
	if cfg.HopRange != "" {
		// hysteria2 share links carry the hopping range as mport.
		q.Set("mport", strings.ReplaceAll(cfg.HopRange, ":", "-"))
	}
	port := portOf(cfg, state.ProtoHysteria2)
	return fmt.Sprintf("hysteria2://%s@%s:%s/?%s#%s-Hysteria2",
		url.User(cfg.Password).String(), host, port, q.Encode(), name)
}

func tuicLink(cfg state.Config, host, name string) string {
	q := url.Values{}
	q.Set("congestion_control", "bbr")
	q.Set("udp_relay_mode", "native")
	q.Set("alpn", "h3")
	q.Set("sni", host)
	q.Set("insecure", "0")
	port := portOf(cfg, state.ProtoTUIC)
	return fmt.Sprintf("tuic://%s@%s:%s?%s#%s-TUIC",
		url.UserPassword(cfg.UUID, cfg.Password).String(), host, port, q.Encode(), name)
}

func vlessLink(cfg state.Config, host, name string) string {
	sni := cfg.RealitySNI
	if sni == "" {
		sni = state.DefaultSNI
	}
	q := url.Values{}
	q.Set("type", "tcp")
	q.Set("encryption", "none")
	q.Set("flow", "xtls-rprx-vision")
	q.Set("security", "reality")
	q.Set("sni", sni)
	q.Set("fp", "chrome")
	q.Set("pbk", cfg.RealityPub)
	q.Set("sid", cfg.RealitySID)
	port := portOf(cfg, state.ProtoVLESSReality)
	return fmt.Sprintf("vless://%s@%s:%s?%s#%s-VLESS-Reality",
		url.User(cfg.UUID).String(), host, port, q.Encode(), name)
}

func portOf(cfg state.Config, key string) string {
	port := cfg.Ports[key]
	if port == "" {
		port = state.DefaultPorts[key]
	}
	return port
}

func vmessLink(cfg state.Config, host, name string) string {
	sni := host
	payload := map[string]any{
		"v":    "2",
		"ps":   name + "-VMess",
		"add":  host,
		"port": portOf(cfg, state.ProtoVMessWSTLS),
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
