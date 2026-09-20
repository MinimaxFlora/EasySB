package state

import "testing"

func TestDefault(t *testing.T) {
	c := Default()
	if !c.AnyEnabled() {
		t.Fatal("default config should enable protocols")
	}
	if !c.NeedsDomain() {
		t.Fatal("default config should need a domain")
	}
	for _, k := range Keys {
		if c.Ports[k] != DefaultPorts[k] {
			t.Fatalf("port %s = %q, want %q", k, c.Ports[k], DefaultPorts[k])
		}
	}
	if c.HopRange != DefaultHopRange || c.RealitySNI != DefaultSNI {
		t.Fatalf("unexpected defaults: %+v", c)
	}
}

func TestApplyRaw(t *testing.T) {
	c := Default()
	c.raw = map[string]string{
		"IS_ANYTLS":        "false",
		"IS_VMESS_WS_TLS":  "true",
		"PORT_ANYTLS":      "9000",
		"HY2_HOP_RANGE":    "3000:4000",
		"DOMAIN":           "example.com",
		"NODE_DEPLOYED":    "yes",
		"REALITY_SHORT_ID": "abcd",
		"CORE_CHANNEL":     "alpha",
		"UNRECOGNISED_KEY": "keep-me",
	}
	c.applyRaw()

	if c.Enabled[ProtoAnyTLS] {
		t.Fatal("IS_ANYTLS=false should disable anytls")
	}
	if !c.Enabled[ProtoVMessWSTLS] {
		t.Fatal("IS_VMESS_WS_TLS=true should enable vmess")
	}
	if c.Ports[ProtoAnyTLS] != "9000" {
		t.Fatalf("port override not applied: %q", c.Ports[ProtoAnyTLS])
	}
	if c.HopRange != "3000:4000" || c.Domain != "example.com" {
		t.Fatalf("raw values not applied: %+v", c)
	}
	if !c.NodeDeployed {
		t.Fatal("NODE_DEPLOYED=yes should set NodeDeployed")
	}
	if c.CoreChannel != "alpha" {
		t.Fatalf("channel = %q", c.CoreChannel)
	}
	extra := c.extraKeys()
	if len(extra) != 1 || extra[0] != "UNRECOGNISED_KEY" {
		t.Fatalf("unexpected extra keys: %v", extra)
	}
}

func TestHost(t *testing.T) {
	c := Default()
	if got := c.Host(); got != "" {
		t.Fatalf("empty host = %q", got)
	}
	c.ServerIP = "1.2.3.4"
	if got := c.Host(); got != "1.2.3.4" {
		t.Fatalf("host = %q", got)
	}
	c.CertDomain = "cert.example.com"
	if got := c.Host(); got != "cert.example.com" {
		t.Fatalf("host = %q", got)
	}
	c.Domain = "example.com"
	if got := c.Host(); got != "example.com" {
		t.Fatalf("host = %q", got)
	}
}

func TestNeedsDomainOnlyReality(t *testing.T) {
	c := Default()
	for _, k := range Keys {
		c.Enabled[k] = k == ProtoVLESSReality
	}
	if c.NeedsDomain() {
		t.Fatal("reality alone should not need a domain")
	}
}
