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

	root := map[string]any{}
	if err := json.Unmarshal(stripJSONC(templateJSON), &root); err != nil {
		return nil, fmt.Errorf("parse subscription template: %w", err)
	}

	outbounds, _ := root["outbounds"].([]any)
	hop := cfg.HopRange
	if hop == "" {
		hop = state.DefaultHopRange
	}
	rsni := cfg.RealitySNI
	if rsni == "" {
		rsni = state.DefaultSNI
	}

	var kept []any
	for _, raw := range outbounds {
		ob, ok := raw.(map[string]any)
		if !ok {
			continue
		}
		tag, _ := ob["tag"].(string)
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

	for _, raw := range kept {
		ob, _ := raw.(map[string]any)
		if ob == nil {
			continue
		}
		switch ob["tag"] {
		case "proxy":
			ob["outbounds"] = append([]string{"auto"}, enabled...)
		case "auto":
			ob["outbounds"] = append([]string{}, enabled...)
		}
	}
	root["outbounds"] = kept

	return json.MarshalIndent(root, "", "  ")
}

func applyNode(ob map[string]any, tag string, cfg state.Config, hop, rsni string) {
	host := cfg.Host()
	ob["server"] = host
	switch tag {
	case "anytls":
		ob["server_port"] = portInt(cfg, state.ProtoAnyTLS)
		ob["password"] = cfg.Password
		setServerName(ob, host)
	case "hysteria2":
		ob["server_ports"] = []string{hop}
		ob["password"] = cfg.Password
		setServerName(ob, host)
	case "tuic":
		ob["server_port"] = portInt(cfg, state.ProtoTUIC)
		ob["uuid"] = cfg.UUID
		ob["password"] = cfg.Password
		setServerName(ob, host)
	case "vmess-ws-tls":
		ob["server_port"] = portInt(cfg, state.ProtoVMessWSTLS)
		ob["uuid"] = cfg.UUID
		setServerName(ob, host)
	case "vless-vision-reality":
		ob["server_port"] = portInt(cfg, state.ProtoVLESSReality)
		ob["uuid"] = cfg.UUID
		setServerName(ob, rsni)
		if tls, ok := ob["tls"].(map[string]any); ok {
			if reality, ok := tls["reality"].(map[string]any); ok {
				reality["public_key"] = cfg.RealityPub
				reality["short_id"] = cfg.RealitySID
			}
		}
	}
}

func setServerName(ob map[string]any, name string) {
	if tls, ok := ob["tls"].(map[string]any); ok {
		tls["server_name"] = name
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
