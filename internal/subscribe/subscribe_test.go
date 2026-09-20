package subscribe

import (
	"encoding/base64"
	"encoding/json"
	"strings"
	"testing"

	"github.com/MinimaxFlora/EasySB/internal/state"
)

func sample() state.Config {
	c := state.Default()
	c.ServerIP = "203.0.113.10"
	c.UUID = "11111111-2222-3333-4444-555555555555"
	c.Password = "secret"
	c.RealityPub = "PUBKEY"
	c.RealitySID = "abcd1234"
	c.RealitySNI = "apple.com"
	return c
}

func TestURLUsesHTTPSchemeWithoutCert(t *testing.T) {
	c := sample()
	got := URL(c)
	want := "http://203.0.113.10:8443/subscribe"
	if got != want {
		t.Fatalf("URL = %q, want %q", got, want)
	}
}

func TestDeepLinkEncodesURL(t *testing.T) {
	link := DeepLink("http://example.com:8443/subscribe")
	if !strings.HasPrefix(link, ImportScheme) {
		t.Fatalf("link missing scheme: %q", link)
	}
	if strings.Contains(link, "://example.com") {
		t.Fatalf("url not percent-encoded: %q", link)
	}
	if !strings.Contains(link, "url=http%3A%2F%2Fexample.com") {
		t.Fatalf("unexpected encoding: %q", link)
	}
}

func TestShareLinks(t *testing.T) {
	c := sample()
	links := ShareLinks(c)
	joined := strings.Join(links, "\n")
	for _, prefix := range []string{"anytls://", "hysteria2://", "tuic://", "vmess://", "vless://"} {
		if !strings.Contains(joined, prefix) {
			t.Fatalf("missing %s link in:\n%s", prefix, joined)
		}
	}

	var vmess string
	for _, l := range links {
		if strings.HasPrefix(l, "vmess://") {
			vmess = strings.TrimPrefix(l, "vmess://")
		}
	}
	raw, err := base64.StdEncoding.DecodeString(vmess)
	if err != nil {
		t.Fatalf("vmess base64 decode: %v", err)
	}
	var payload map[string]any
	if err := json.Unmarshal(raw, &payload); err != nil {
		t.Fatalf("vmess json decode: %v", err)
	}
	if payload["add"] != "203.0.113.10" || payload["id"] != c.UUID {
		t.Fatalf("unexpected vmess payload: %v", payload)
	}
}

func TestShareLinksRespectsDisabled(t *testing.T) {
	c := sample()
	for _, k := range state.Keys {
		c.Enabled[k] = k == state.ProtoVLESSReality
	}
	links := ShareLinks(c)
	if len(links) != 1 || !strings.HasPrefix(links[0], "vless://") {
		t.Fatalf("expected only vless link, got %v", links)
	}
}

func TestClientURLs(t *testing.T) {
	c := sample()
	if got := ClientPath(c, ClientSingBox); got != "/singbox/"+c.UUID {
		t.Fatalf("ClientPath = %q", got)
	}
	want := "http://203.0.113.10:8443/mihomo/" + c.UUID
	if got := ClientURL(c, ClientMihomo); got != want {
		t.Fatalf("ClientURL = %q, want %q", got, want)
	}
	if got := ClientLink(c, ClientV2Ray); got != ClientURL(c, ClientV2Ray) {
		t.Fatalf("v2ray link should be the plain URL: %q", got)
	}
	if got := ClientLink(c, ClientSingBox); !strings.HasPrefix(got, ImportScheme) {
		t.Fatalf("sing-box link missing deep link scheme: %q", got)
	}
	// Clash-family clients fetch the scanned payload as a profile URL, so the
	// mihomo QR must carry the plain endpoint rather than a clash:// deep link.
	if got := ClientLink(c, ClientMihomo); got != ClientURL(c, ClientMihomo) {
		t.Fatalf("mihomo link should be the plain URL: %q", got)
	}
}

func TestShareLinksEncodeCredentials(t *testing.T) {
	c := sample()
	c.Password = "p@ss/word"
	links := ShareLinks(c)
	joined := strings.Join(links, "\n")
	if strings.Contains(joined, "p@ss/word") {
		t.Fatalf("password not percent-encoded:\n%s", joined)
	}
	// AnyTLS and Hysteria2 URIs require a slash before the query, otherwise
	// clients reject the link.
	if !strings.Contains(joined, "anytls://p%40ss%2Fword@203.0.113.10:8000/?") {
		t.Fatalf("anytls link malformed:\n%s", joined)
	}
	if !strings.Contains(joined, "hysteria2://p%40ss%2Fword@203.0.113.10:8001/?") {
		t.Fatalf("hysteria2 link malformed:\n%s", joined)
	}
}

func TestV2RaySubscription(t *testing.T) {
	c := sample()
	raw, err := base64.StdEncoding.DecodeString(V2RaySubscription(c))
	if err != nil {
		t.Fatalf("decode v2ray document: %v", err)
	}
	if !strings.Contains(string(raw), "vless://") {
		t.Fatalf("v2ray document missing share links:\n%s", raw)
	}
}
