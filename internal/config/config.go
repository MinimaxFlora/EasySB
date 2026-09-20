// Package config renders the sing-box server configuration from the EasySB
// state. The produced document matches the layout of the legacy shell tool so
// existing deployments keep working after the Go rewrite.
package config

import (
	"encoding/json"
	"errors"
	"fmt"

	"github.com/MinimaxFlora/EasySB/internal/state"
)

// Params is the input needed to render config.json.
type Params struct {
	Enabled       map[string]bool
	Ports         map[string]string
	Password      string
	UUID          string
	HopRange      string
	RealitySNI    string
	RealityPriv   string
	RealitySID    string
	CertFullchain string
	CertKey       string
}

// ParamsFromState maps a persisted config into rendering parameters.
func ParamsFromState(c state.Config) Params {
	return Params{
		Enabled:     c.Enabled,
		Ports:       c.Ports,
		Password:    c.Password,
		UUID:        c.UUID,
		HopRange:    c.HopRange,
		RealitySNI:  c.RealitySNI,
		RealityPriv: c.RealityPriv,
		RealitySID:  c.RealitySID,
	}
}

var paddingScheme = []string{
	"stop=8",
	"0=30-30",
	"1=100-400",
	"2=400-500,c,500-1000,c,500-1000,c,500-1000,c,500-1000",
	"3=9-9,500-1000",
	"4=500-1000",
	"5=500-1000",
	"6=500-1000",
	"7=500-1000",
}

// NeedsCert reports whether any enabled protocol (other than Reality) requires
// a TLS certificate.
func (p Params) NeedsCert() bool {
	for _, k := range state.Keys {
		if k == state.ProtoVLESSReality {
			continue
		}
		if p.Enabled[k] {
			return true
		}
	}
	return false
}

// Build renders the complete server configuration document.
func Build(p Params) ([]byte, error) {
	inbounds, err := buildInbounds(p)
	if err != nil {
		return nil, err
	}
	doc := serverConfig{
		Log:       logConfig{Level: "info", Timestamp: true},
		Inbounds:  inbounds,
		Outbounds: []outbound{{Type: "direct", Tag: "direct"}},
	}
	return json.MarshalIndent(doc, "", "  ")
}

type serverConfig struct {
	Log       logConfig  `json:"log"`
	Inbounds  []any      `json:"inbounds"`
	Outbounds []outbound `json:"outbounds"`
}

type logConfig struct {
	Level     string `json:"level"`
	Timestamp bool   `json:"timestamp"`
}

type outbound struct {
	Type string `json:"type"`
	Tag  string `json:"tag"`
}

type user struct {
	Name     string `json:"name,omitempty"`
	Password string `json:"password,omitempty"`
	UUID     string `json:"uuid,omitempty"`
	Flow     string `json:"flow,omitempty"`
	AlterID  *int   `json:"alterId,omitempty"`
}

type tlsConfig struct {
	Enabled         bool           `json:"enabled"`
	CertificatePath string         `json:"certificate_path,omitempty"`
	KeyPath         string         `json:"key_path,omitempty"`
	ServerName      string         `json:"server_name,omitempty"`
	ALPN            []string       `json:"alpn,omitempty"`
	Reality         *realityConfig `json:"reality,omitempty"`
}

type realityConfig struct {
	Enabled   bool      `json:"enabled"`
	Handshake handshake `json:"handshake"`
	Private   string    `json:"private_key"`
	ShortID   []string  `json:"short_id"`
}

type handshake struct {
	Server string `json:"server"`
	Port   int    `json:"server_port"`
}

func (p Params) port(key string) (int, error) {
	raw := p.Ports[key]
	if raw == "" {
		raw = state.DefaultPorts[key]
	}
	var n int
	if _, err := fmt.Sscanf(raw, "%d", &n); err != nil || n < 1 || n > 65535 {
		return 0, fmt.Errorf("invalid port %q for %s", raw, key)
	}
	return n, nil
}

func (p Params) base(key string) (map[string]any, error) {
	port, err := p.port(key)
	if err != nil {
		return nil, err
	}
	return map[string]any{
		"tag":         key,
		"listen":      "::",
		"listen_port": port,
	}, nil
}

func (p Params) certTLS(alpn []string) tlsConfig {
	return tlsConfig{
		Enabled:         true,
		CertificatePath: p.CertFullchain,
		KeyPath:         p.CertKey,
		ALPN:            alpn,
	}
}

func buildInbounds(p Params) ([]any, error) {
	var out []any

	if p.Enabled[state.ProtoAnyTLS] {
		m, err := p.base(state.ProtoAnyTLS)
		if err != nil {
			return nil, err
		}
		m["type"] = "anytls"
		m["users"] = []user{{Name: "easysb", Password: p.Password}}
		m["padding_scheme"] = paddingScheme
		m["tls"] = p.certTLS([]string{"h3", "h2", "http/1.1"})
		out = append(out, m)
	}

	if p.Enabled[state.ProtoHysteria2] {
		m, err := p.base(state.ProtoHysteria2)
		if err != nil {
			return nil, err
		}
		m["type"] = "hysteria2"
		m["up_mbps"] = 100
		m["down_mbps"] = 20
		m["users"] = []user{{Name: "easysb", Password: p.Password}}
		tls := p.certTLS([]string{"h3"})
		m["tls"] = tls
		out = append(out, m)
	}

	if p.Enabled[state.ProtoTUIC] {
		m, err := p.base(state.ProtoTUIC)
		if err != nil {
			return nil, err
		}
		m["type"] = "tuic"
		m["users"] = []user{{UUID: p.UUID, Password: p.Password}}
		m["congestion_control"] = "bbr"
		m["auth_timeout"] = "3s"
		m["zero_rtt_handshake"] = false
		m["heartbeat"] = "10s"
		m["tls"] = p.certTLS([]string{"h3"})
		out = append(out, m)
	}

	if p.Enabled[state.ProtoVLESSReality] {
		m, err := p.base(state.ProtoVLESSReality)
		if err != nil {
			return nil, err
		}
		m["type"] = "vless"
		m["tag"] = state.ProtoVLESSReality
		m["users"] = []user{{Name: "easysb", UUID: p.UUID, Flow: "xtls-rprx-vision"}}
		m["tls"] = tlsConfig{
			Enabled:    true,
			ServerName: p.RealitySNI,
			Reality: &realityConfig{
				Enabled:   true,
				Handshake: handshake{Server: p.RealitySNI, Port: 443},
				Private:   p.RealityPriv,
				ShortID:   []string{p.RealitySID},
			},
		}
		out = append(out, m)
	}

	if p.Enabled[state.ProtoVMessWSTLS] {
		m, err := p.base(state.ProtoVMessWSTLS)
		if err != nil {
			return nil, err
		}
		zero := 0
		m["type"] = "vmess"
		m["users"] = []user{{Name: "easysb", UUID: p.UUID, AlterID: &zero}}
		m["multiplex"] = map[string]any{"enabled": true, "padding": false}
		m["transport"] = map[string]any{
			"type":                   "ws",
			"path":                   "/vmess",
			"max_early_data":         2048,
			"early_data_header_name": "Sec-WebSocket-Protocol",
		}
		m["tls"] = p.certTLS(nil)
		out = append(out, m)
	}

	if len(out) == 0 {
		return nil, errors.New("no protocol enabled")
	}
	return out, nil
}
