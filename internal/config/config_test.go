package config

import (
	"encoding/json"
	"testing"

	"github.com/MinimaxFlora/EasySB/internal/state"
)

func fullParams() Params {
	c := state.Default()
	c.UUID = "11111111-2222-3333-4444-555555555555"
	c.Password = "secret"
	c.RealityPriv = "priv"
	c.RealityPub = "pub"
	c.RealitySID = "abcd1234"
	c.RealitySNI = "apple.com"
	return Params{
		Enabled:       c.Enabled,
		Ports:         c.Ports,
		Password:      c.Password,
		UUID:          c.UUID,
		HopRange:      c.HopRange,
		RealitySNI:    c.RealitySNI,
		RealityPriv:   c.RealityPriv,
		RealitySID:    c.RealitySID,
		CertFullchain: "/etc/sing-box/cert/fullchain.cer",
		CertKey:       "/etc/sing-box/cert/private.key",
	}
}

type parsedConfig struct {
	Log       struct{ Level string } `json:"log"`
	Inbounds  []map[string]any       `json:"inbounds"`
	Outbounds []struct {
		Type string `json:"type"`
		Tag  string `json:"tag"`
	} `json:"outbounds"`
}

func TestBuildAllProtocols(t *testing.T) {
	data, err := Build(fullParams())
	if err != nil {
		t.Fatalf("Build: %v", err)
	}
	var parsed parsedConfig
	if err := json.Unmarshal(data, &parsed); err != nil {
		t.Fatalf("invalid JSON: %v", err)
	}
	if len(parsed.Inbounds) != 5 {
		t.Fatalf("expected 5 inbounds, got %d", len(parsed.Inbounds))
	}
	if len(parsed.Outbounds) != 1 || parsed.Outbounds[0].Tag != "direct" {
		t.Fatalf("unexpected outbounds: %+v", parsed.Outbounds)
	}

	byTag := map[string]map[string]any{}
	for _, in := range parsed.Inbounds {
		byTag[in["tag"].(string)] = in
	}
	for _, tag := range state.Keys {
		if _, ok := byTag[tag]; !ok {
			t.Fatalf("missing inbound %s", tag)
		}
	}
	if p := byTag[state.ProtoAnyTLS]["listen_port"].(float64); p != 8000 {
		t.Fatalf("anytls port = %v", p)
	}
	if p := byTag[state.ProtoVMessWSTLS]["listen_port"].(float64); p != 8004 {
		t.Fatalf("vmess port = %v", p)
	}
	reality := byTag[state.ProtoVLESSReality]["tls"].(map[string]any)["reality"].(map[string]any)
	if reality["private_key"] != "priv" {
		t.Fatalf("reality private key = %v", reality["private_key"])
	}
}

func TestBuildRespectsDisabled(t *testing.T) {
	p := fullParams()
	p.Enabled = map[string]bool{state.ProtoAnyTLS: true}
	data, err := Build(p)
	if err != nil {
		t.Fatalf("Build: %v", err)
	}
	var parsed parsedConfig
	if err := json.Unmarshal(data, &parsed); err != nil {
		t.Fatal(err)
	}
	if len(parsed.Inbounds) != 1 {
		t.Fatalf("expected 1 inbound, got %d", len(parsed.Inbounds))
	}
	if parsed.Inbounds[0]["type"] != "anytls" {
		t.Fatalf("unexpected inbound: %+v", parsed.Inbounds[0])
	}
}

func TestBuildNoProtocol(t *testing.T) {
	p := fullParams()
	p.Enabled = map[string]bool{}
	if _, err := Build(p); err == nil {
		t.Fatal("expected error when no protocol is enabled")
	}
}

func TestBuildInvalidPort(t *testing.T) {
	p := fullParams()
	p.Enabled = map[string]bool{state.ProtoAnyTLS: true}
	p.Ports = map[string]string{state.ProtoAnyTLS: "70000"}
	if _, err := Build(p); err == nil {
		t.Fatal("expected error for out-of-range port")
	}
}

func TestNeedsCert(t *testing.T) {
	p := fullParams()
	if !p.NeedsCert() {
		t.Fatal("expected cert requirement with TLS protocols enabled")
	}
	p.Enabled = map[string]bool{state.ProtoVLESSReality: true}
	if p.NeedsCert() {
		t.Fatal("reality alone should not require a cert")
	}
}
