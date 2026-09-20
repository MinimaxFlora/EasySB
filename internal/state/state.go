// Package state reads and writes the EasySB node state file
// (/etc/sing-box/easysb.conf), keeping the on-disk format compatible with the
// legacy shell implementation so both can inspect the same deployment.
package state

import (
	"bufio"
	"fmt"
	"os"
	"sort"
	"strings"

	"github.com/MinimaxFlora/EasySB/internal/sysinfo"
)

// Protocol keys used across the state file and config generation.
const (
	ProtoAnyTLS       = "anytls"
	ProtoHysteria2    = "hysteria2"
	ProtoTUIC         = "tuic"
	ProtoVLESSReality = "vless-reality"
	ProtoVMessWSTLS   = "vmess-ws-tls"
)

// Keys lists protocols in the canonical order.
var Keys = []string{ProtoAnyTLS, ProtoHysteria2, ProtoTUIC, ProtoVLESSReality, ProtoVMessWSTLS}

// Labels maps protocol keys to human readable names.
var Labels = map[string]string{
	ProtoAnyTLS:       "AnyTLS",
	ProtoHysteria2:    "Hysteria2",
	ProtoTUIC:         "TUIC v5",
	ProtoVLESSReality: "VLESS-Vision-Reality",
	ProtoVMessWSTLS:   "VMess-WebSocket-TLS",
}

// DefaultPorts maps protocol keys to their default listen ports.
var DefaultPorts = map[string]string{
	ProtoAnyTLS:       "8000",
	ProtoHysteria2:    "8001",
	ProtoTUIC:         "8002",
	ProtoVLESSReality: "8003",
	ProtoVMessWSTLS:   "8004",
}

// Defaults for optional parameters.
const (
	DefaultHopRange = "2080:3000"
	DefaultSNI      = "apple.com"
	DefaultSubPort  = "8443"
	DefaultSubPath  = "/subscribe"
	DefaultChannel  = "stable"
)

// Config is the persisted node configuration.
type Config struct {
	Enabled      map[string]bool
	Ports        map[string]string
	HopRange     string
	RealitySNI   string
	RealityPriv  string
	RealityPub   string
	RealitySID   string
	UUID         string
	Password     string
	Domain       string
	CertDomain   string
	CoreChannel  string
	NodeDeployed bool
	SubPort      string
	SubPath      string
	ServerIP     string
	raw          map[string]string
}

// Default returns a Config populated with built-in defaults.
func Default() Config {
	c := Config{
		Enabled:      map[string]bool{},
		Ports:        map[string]string{},
		HopRange:     DefaultHopRange,
		RealitySNI:   DefaultSNI,
		CoreChannel:  DefaultChannel,
		SubPort:      DefaultSubPort,
		SubPath:      DefaultSubPath,
		NodeDeployed: false,
		raw:          map[string]string{},
	}
	for _, k := range Keys {
		c.Enabled[k] = true
		c.Ports[k] = DefaultPorts[k]
	}
	return c
}

// Load reads the state file, applying defaults for any missing value.
func Load() Config {
	c := Default()
	f, err := os.Open(sysinfo.StateFile)
	if err != nil {
		return c
	}
	defer f.Close()

	sc := bufio.NewScanner(f)
	for sc.Scan() {
		line := strings.TrimSpace(sc.Text())
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		key, val, ok := strings.Cut(line, "=")
		if !ok {
			continue
		}
		key = strings.TrimSpace(key)
		val = strings.Trim(strings.TrimSpace(val), `"'`)
		c.raw[key] = val
	}
	c.applyRaw()
	return c
}

func (c *Config) applyRaw() {
	enabledKey := map[string]string{
		ProtoAnyTLS:       "IS_ANYTLS",
		ProtoHysteria2:    "IS_HYSTERIA2",
		ProtoTUIC:         "IS_TUIC",
		ProtoVLESSReality: "IS_VLESS_REALITY",
		ProtoVMessWSTLS:   "IS_VMESS_WS_TLS",
	}
	portKey := map[string]string{
		ProtoAnyTLS:       "PORT_ANYTLS",
		ProtoHysteria2:    "PORT_HYSTERIA2",
		ProtoTUIC:         "PORT_TUIC",
		ProtoVLESSReality: "PORT_VLESS_REALITY",
		ProtoVMessWSTLS:   "PORT_VMESS_WS_TLS",
	}
	for _, k := range Keys {
		if v, ok := c.raw[enabledKey[k]]; ok {
			c.Enabled[k] = strings.EqualFold(v, "true") || v == "yes" || v == "1"
		}
		if v := c.raw[portKey[k]]; v != "" {
			c.Ports[k] = v
		}
	}
	set := func(dst *string, key string) {
		if v := c.raw[key]; v != "" {
			*dst = v
		}
	}
	set(&c.HopRange, "HY2_HOP_RANGE")
	set(&c.RealitySNI, "REALITY_SNI")
	set(&c.RealityPriv, "REALITY_PRIVATE")
	set(&c.RealityPub, "REALITY_PUBLIC")
	set(&c.RealitySID, "REALITY_SHORT_ID")
	set(&c.UUID, "UUID")
	set(&c.Password, "PASSWORD")
	set(&c.Domain, "DOMAIN")
	set(&c.CertDomain, "CERT_DOMAIN")
	set(&c.CoreChannel, "CORE_CHANNEL")
	set(&c.SubPort, "SUB_PORT")
	set(&c.SubPath, "SUB_PATH")
	set(&c.ServerIP, "SERVER_IP")
	if v, ok := c.raw["NODE_DEPLOYED"]; ok {
		c.NodeDeployed = strings.EqualFold(v, "yes")
	}
}

// AnyEnabled reports whether at least one protocol is enabled.
func (c Config) AnyEnabled() bool {
	for _, k := range Keys {
		if c.Enabled[k] {
			return true
		}
	}
	return false
}

// NeedsDomain reports whether any enabled protocol requires a certificate.
func (c Config) NeedsDomain() bool {
	for _, k := range Keys {
		if k == ProtoVLESSReality {
			continue
		}
		if c.Enabled[k] {
			return true
		}
	}
	return false
}

// Host returns the public host used by subscriptions and share links.
func (c Config) Host() string {
	if c.Domain != "" {
		return c.Domain
	}
	if c.CertDomain != "" {
		return c.CertDomain
	}
	return c.ServerIP
}

// Save writes the state back to disk with 0600 permissions.
func (c Config) Save() error {
	if err := os.MkdirAll(sysinfo.WorkDir, 0o755); err != nil {
		return err
	}
	enabledKey := map[string]string{
		ProtoAnyTLS:       "IS_ANYTLS",
		ProtoHysteria2:    "IS_HYSTERIA2",
		ProtoTUIC:         "IS_TUIC",
		ProtoVLESSReality: "IS_VLESS_REALITY",
		ProtoVMessWSTLS:   "IS_VMESS_WS_TLS",
	}
	portKey := map[string]string{
		ProtoAnyTLS:       "PORT_ANYTLS",
		ProtoHysteria2:    "PORT_HYSTERIA2",
		ProtoTUIC:         "PORT_TUIC",
		ProtoVLESSReality: "PORT_VLESS_REALITY",
		ProtoVMessWSTLS:   "PORT_VMESS_WS_TLS",
	}

	lines := []string{"# EasySB state"}
	for _, k := range Keys {
		lines = append(lines, fmt.Sprintf("%s=%q", enabledKey[k], boolStr(c.Enabled[k])))
	}
	for _, k := range Keys {
		lines = append(lines, fmt.Sprintf("%s=%q", portKey[k], c.Ports[k]))
	}
	deployed := "no"
	if c.NodeDeployed {
		deployed = "yes"
	}
	pairs := [][2]string{
		{"HY2_HOP_RANGE", c.HopRange},
		{"REALITY_SNI", c.RealitySNI},
		{"REALITY_PRIVATE", c.RealityPriv},
		{"REALITY_PUBLIC", c.RealityPub},
		{"REALITY_SHORT_ID", c.RealitySID},
		{"UUID", c.UUID},
		{"PASSWORD", c.Password},
		{"DOMAIN", c.Domain},
		{"CERT_DOMAIN", c.CertDomain},
		{"CORE_CHANNEL", c.CoreChannel},
		{"NODE_DEPLOYED", deployed},
		{"SUB_PORT", c.SubPort},
		{"SUB_PATH", c.SubPath},
		{"SERVER_IP", c.ServerIP},
	}
	for _, p := range pairs {
		lines = append(lines, fmt.Sprintf("%s=%q", p[0], p[1]))
	}

	// Preserve any unrecognised keys from the previous file.
	for _, k := range c.extraKeys() {
		lines = append(lines, fmt.Sprintf("%s=%q", k, c.raw[k]))
	}

	tmp := sysinfo.StateFile + ".tmp"
	if err := os.WriteFile(tmp, []byte(strings.Join(lines, "\n")+"\n"), 0o600); err != nil {
		return err
	}
	return os.Rename(tmp, sysinfo.StateFile)
}

func (c Config) extraKeys() []string {
	known := map[string]bool{
		"IS_ANYTLS": true, "IS_HYSTERIA2": true, "IS_TUIC": true,
		"IS_VLESS_REALITY": true, "IS_VMESS_WS_TLS": true,
		"PORT_ANYTLS": true, "PORT_HYSTERIA2": true, "PORT_TUIC": true,
		"PORT_VLESS_REALITY": true, "PORT_VMESS_WS_TLS": true,
		"HY2_HOP_RANGE": true, "REALITY_SNI": true, "REALITY_PRIVATE": true,
		"REALITY_PUBLIC": true, "REALITY_SHORT_ID": true, "UUID": true,
		"PASSWORD": true, "DOMAIN": true, "CERT_DOMAIN": true,
		"CORE_CHANNEL": true, "NODE_DEPLOYED": true, "SUB_PORT": true,
		"SUB_PATH": true, "SERVER_IP": true,
	}
	var out []string
	for k := range c.raw {
		if !known[k] {
			out = append(out, k)
		}
	}
	sort.Strings(out)
	return out
}

func boolStr(b bool) string {
	if b {
		return "true"
	}
	return "false"
}
