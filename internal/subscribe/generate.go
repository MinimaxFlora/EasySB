package subscribe

import (
	_ "embed"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strconv"
	"strings"

	"github.com/MinimaxFlora/EasySB/internal/state"
	"github.com/MinimaxFlora/EasySB/internal/sysinfo"
)

//go:embed tun-fakeip.json
var templateJSON []byte

// tagFor maps a state protocol key to the tag used inside the client template.
var tagFor = map[string]string{
	state.ProtoAnyTLS:       "anytls",
	state.ProtoHysteria2:    "hysteria2",
	state.ProtoTUIC:         "tuic",
	state.ProtoVMessWSTLS:   "vmess-ws-tls",
	state.ProtoVLESSReality: "vless-vision-reality",
}

// tagOrder is the canonical template node order.
var tagOrder = []string{"anytls", "hysteria2", "tuic", "vmess-ws-tls", "vless-vision-reality"}

// EnabledTags returns the client tags for every enabled protocol, in canonical
// order.
func EnabledTags(cfg state.Config) []string {
	var out []string
	for _, tag := range tagOrder {
		for _, key := range state.Keys {
			if tagFor[key] == tag && cfg.Enabled[key] {
				out = append(out, tag)
				break
			}
		}
	}
	return out
}

// Generate renders the client subscription (subscribe.json) from the state.
func Generate(cfg state.Config) ([]byte, error) {
	if cfg.Host() == "" {
		return nil, fmt.Errorf("no server address")
	}
	enabled := EnabledTags(cfg)
	if len(enabled) == 0 {
		return nil, fmt.Errorf("no protocol enabled")
	}

	root, err := parseOrderedJSON(stripJSONC(templateJSON))
	if err != nil {
		return nil, fmt.Errorf("parse subscription template: %w", err)
	}

	outbounds := root.get("outbounds")
	if !outbounds.array() {
		return nil, fmt.Errorf("subscription template has no outbounds")
	}
	hop := cfg.HopRange
	if hop == "" {
		hop = state.DefaultHopRange
	}
	rsni := cfg.RealitySNI
	if rsni == "" {
		rsni = state.DefaultSNI
	}

	var kept []*jsonValue
	for _, ob := range outbounds.arr {
		tag := ob.get("tag").asString()
		switch tag {
		case "proxy", "auto", "direct":
			kept = append(kept, ob)
			continue
		}
		if !contains(enabled, tag) {
			continue
		}
		applyNode(ob, tag, cfg, hop, rsni)
		kept = append(kept, ob)
	}

	for _, ob := range kept {
		switch ob.get("tag").asString() {
		case "proxy":
			ob.setStrings("outbounds", append([]string{"auto"}, enabled...))
		case "auto":
			ob.setStrings("outbounds", append([]string{}, enabled...))
		}
	}
	outbounds.arr = kept

	return json.MarshalIndent(root, "", "  ")
}

func applyNode(ob *jsonValue, tag string, cfg state.Config, hop, rsni string) {
	host := cfg.Host()
	ob.setString("server", host)
	switch tag {
	case "anytls":
		ob.setNumber("server_port", portInt(cfg, state.ProtoAnyTLS))
		ob.setString("password", cfg.Password)
		setServerName(ob, host)
	case "hysteria2":
		ob.setStrings("server_ports", []string{hop})
		ob.setString("password", cfg.Password)
		setServerName(ob, host)
	case "tuic":
		ob.setNumber("server_port", portInt(cfg, state.ProtoTUIC))
		ob.setString("uuid", cfg.UUID)
		ob.setString("password", cfg.Password)
		setServerName(ob, host)
	case "vmess-ws-tls":
		ob.setNumber("server_port", portInt(cfg, state.ProtoVMessWSTLS))
		ob.setString("uuid", cfg.UUID)
		setServerName(ob, host)
	case "vless-vision-reality":
		ob.setNumber("server_port", portInt(cfg, state.ProtoVLESSReality))
		ob.setString("uuid", cfg.UUID)
		setServerName(ob, rsni)
		if tls := ob.get("tls"); tls != nil {
			if reality := tls.get("reality"); reality != nil {
				reality.setString("public_key", cfg.RealityPub)
				reality.setString("short_id", cfg.RealitySID)
			}
		}
	}
}

func setServerName(ob *jsonValue, name string) {
	if tls := ob.get("tls"); tls != nil {
		tls.setString("server_name", name)
	}
}

func portInt(cfg state.Config, key string) int {
	raw := cfg.Ports[key]
	if raw == "" {
		raw = state.DefaultPorts[key]
	}
	n, _ := strconv.Atoi(raw)
	return n
}

// GenerateFiles renders every client subscription document plus the share-link
// list into the subscribe directory and returns the files it wrote.
func GenerateFiles(cfg state.Config) ([]string, error) {
	jsonData, err := Generate(cfg)
	if err != nil {
		return nil, err
	}
	yamlData, err := GenerateMihomo(cfg)
	if err != nil {
		return nil, err
	}
	if err := os.MkdirAll(sysinfo.SubscribeDir, 0o755); err != nil {
		return nil, err
	}

	files := []struct {
		name string
		data []byte
	}{
		{ClientFile(ClientSingBox), jsonData},
		{ClientFile(ClientMihomo), yamlData},
		{ClientFile(ClientV2Ray), []byte(V2RaySubscription(cfg) + "\n")},
		{"share-links.txt", []byte(strings.Join(ShareLinks(cfg), "\n") + "\n")},
	}

	written := make([]string, 0, len(files))
	for _, f := range files {
		path := filepath.Join(sysinfo.SubscribeDir, f.name)
		if err := os.WriteFile(path, f.data, 0o644); err != nil {
			return written, err
		}
		written = append(written, path)
	}
	return written, nil
}

// stripJSONC removes // line comments that appear outside string literals.
func stripJSONC(in []byte) []byte {
	var out []byte
	for _, line := range strings.Split(string(in), "\n") {
		quoted := false
		cut := len(line)
		for i := 0; i < len(line); i++ {
			c := line[i]
			if c == '"' {
				quoted = !quoted
				continue
			}
			if !quoted && c == '/' && i+1 < len(line) && line[i+1] == '/' {
				cut = i
				break
			}
		}
		out = append(out, line[:cut]...)
		out = append(out, '\n')
	}
	return out
}

func contains(list []string, v string) bool {
	for _, item := range list {
		if item == v {
			return true
		}
	}
	return false
}
