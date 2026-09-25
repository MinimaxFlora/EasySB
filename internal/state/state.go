// Package state reads and writes the EasySB node state file
// (/etc/sing-box/easysb.conf). The key/value layout is kept from the legacy
// shell implementation, but v4 drops the node-wide credential and the nginx
// subscription keys: credentials belong to the accounts in internal/user, and
// the endpoint is built from SUB_SERVE_PORT.
package state

import (
	"bufio"
	"fmt"
	"os"
	"sort"
	"strconv"
	"strings"
	"time"

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
	DefaultChannel  = "stable"

	// DefaultSubServePort is the listen port of the built-in subscription
	// service that replaced the nginx site.
	DefaultSubServePort = 8443
	// DefaultSubSyncSeconds is how often usage is read from the core.
	DefaultSubSyncSeconds = 300
	// MinSubSyncSeconds bounds the accounting interval. A shorter interval only
	// adds gRPC round trips and config rewrites.
	MinSubSyncSeconds = 30
	// DefaultFrontPort is where the camouflage site listens: the whole point of
	// it is that the domain looks like an ordinary HTTPS site.
	DefaultFrontPort = 443
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
	Domain       string
	CertDomain   string
	ACMEEmail    string
	CoreChannel  string
	NodeDeployed bool
	// StatsAPI records which counter source the deployed core offers. It is
	// "none" when the core was built without the V2Ray API, which is the case
	// for the official release builds: the config then carries no
	// experimental.v2ray_api block, because sing-box refuses a config that
	// names an API it was not built with. Empty means the historical value
	// ("v2ray"), so an existing deployment keeps its counters.
	StatsAPI string
	// CoreSource records where the installed core came from ("build" for this
	// repository's builds, "upstream" for the official releases), so the panel can
	// say which source is installed. Empty on an install made before the record.
	CoreSource   string
	SubServePort int
	SubSyncSecs  int
	ServerIP     string
	// FrontEnabled turns the camouflage site on: the domain is then served by
	// this panel's own HTTPS front, which routes /sub/ to the subscription
	// service and everything else to the application picked in FrontApp.
	FrontEnabled bool
	// FrontApp is the application ID the front serves, empty when none is picked.
	FrontApp string
	// FrontPort is the port the front listens on; 443 unless the operator moved
	// it, which is only useful when something else already owns 443.
	FrontPort int
	// AppPorts records the port each installed application listens on, keyed by
	// application ID. An application with no record uses its own default.
	AppPorts map[string]string
	raw      map[string]string
}

// StatsAPINone is the StatsAPI value for a core without the V2Ray API.
const StatsAPINone = "none"

// V2RayStats reports whether the core being configured offers the V2Ray stats
// API, which is where the per-account byte counters come from.
func (c Config) V2RayStats() bool { return !strings.EqualFold(c.StatsAPI, StatsAPINone) }

// AppPort is the port an installed application was configured with, 0 when the
// state file has no record (the caller then uses the catalogue default).
func (c Config) AppPort(id string) int {
	if n, err := strconv.Atoi(c.AppPorts[id]); err == nil && n > 0 && n < 65536 {
		return n
	}
	return 0
}

// SetAppPort records the port an application listens on.
func (c *Config) SetAppPort(id string, port int) {
	if c.AppPorts == nil {
		c.AppPorts = map[string]string{}
	}
	c.AppPorts[id] = strconv.Itoa(port)
}

// FrontListen is the address the camouflage front binds, empty when it is off.
func (c Config) FrontListen() string {
	if !c.FrontEnabled {
		return ""
	}
	if c.FrontPort <= 0 {
		return fmt.Sprintf(":%d", DefaultFrontPort)
	}
	return fmt.Sprintf(":%d", c.FrontPort)
}

// Default returns a Config populated with built-in defaults.
func Default() Config {
	c := Config{
		Enabled:      map[string]bool{},
		Ports:        map[string]string{},
		HopRange:     DefaultHopRange,
		RealitySNI:   DefaultSNI,
		CoreChannel:  DefaultChannel,
		SubServePort: DefaultSubServePort,
		SubSyncSecs:  DefaultSubSyncSeconds,
		NodeDeployed: false,
		FrontPort:    DefaultFrontPort,
		AppPorts:     map[string]string{},
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
	set(&c.Domain, "DOMAIN")
	set(&c.CertDomain, "CERT_DOMAIN")
	set(&c.ACMEEmail, "ACME_EMAIL")
	set(&c.CoreChannel, "CORE_CHANNEL")
	set(&c.ServerIP, "SERVER_IP")
	set(&c.StatsAPI, "STATS_API")
	set(&c.CoreSource, "CORE_SOURCE")
	if n, err := strconv.Atoi(c.raw["SUB_SERVE_PORT"]); err == nil && n > 0 && n < 65536 {
		c.SubServePort = n
	}
	if v, ok := c.raw["FRONT_ENABLED"]; ok {
		c.FrontEnabled = strings.EqualFold(v, "yes")
	}
	c.FrontApp = c.raw["FRONT_APP"]
	if n, err := strconv.Atoi(c.raw["FRONT_PORT"]); err == nil && n > 0 && n < 65536 {
		c.FrontPort = n
	}
	// Application ports are recorded as APP_<ID>_PORT, so adding an application
	// to the catalogue needs no change here.
	for key, val := range c.raw {
		if !strings.HasPrefix(key, "APP_") || !strings.HasSuffix(key, "_PORT") {
			continue
		}
		id := strings.ToLower(strings.TrimSuffix(strings.TrimPrefix(key, "APP_"), "_PORT"))
		if id == "" {
			continue
		}
		if n, err := strconv.Atoi(val); err == nil && n > 0 && n < 65536 {
			c.AppPorts[id] = val
		}
	}
	if n, err := strconv.Atoi(c.raw["SUB_SYNC_SECONDS"]); err == nil && n > 0 {
		c.SubSyncSecs = n
	}
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

// SyncInterval is the accounting interval, never shorter than
// MinSubSyncSeconds however the state file was edited.
func (c Config) SyncInterval() time.Duration {
	secs := c.SubSyncSecs
	if secs < MinSubSyncSeconds {
		secs = MinSubSyncSeconds
	}
	return time.Duration(secs) * time.Second
}

// SubPort is the effective port of the subscription endpoint.
func (c Config) SubPort() int {
	if c.SubServePort > 0 {
		return c.SubServePort
	}
	return DefaultSubServePort
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
		{"DOMAIN", c.Domain},
		{"CERT_DOMAIN", c.CertDomain},
		{"ACME_EMAIL", c.ACMEEmail},
		{"CORE_CHANNEL", c.CoreChannel},
		{"NODE_DEPLOYED", deployed},
		{"STATS_API", c.StatsAPI},
		{"CORE_SOURCE", c.CoreSource},
		{"SUB_SERVE_PORT", strconv.Itoa(c.SubServePort)},
		{"FRONT_ENABLED", yesNo(c.FrontEnabled)},
		{"FRONT_APP", c.FrontApp},
		{"FRONT_PORT", strconv.Itoa(c.FrontPort)},
		{"SUB_SYNC_SECONDS", strconv.Itoa(c.SubSyncSecs)},
		{"SERVER_IP", c.ServerIP},
	}
	for _, p := range pairs {
		lines = append(lines, fmt.Sprintf("%s=%q", p[0], p[1]))
	}

	// Application ports are written from the map, so an application added to the
	// catalogue is remembered without touching this function.
	ids := make([]string, 0, len(c.AppPorts))
	for id := range c.AppPorts {
		ids = append(ids, id)
	}
	sort.Strings(ids)
	for _, id := range ids {
		if c.AppPorts[id] == "" {
			continue
		}
		lines = append(lines, fmt.Sprintf("APP_%s_PORT=%q", strings.ToUpper(id), c.AppPorts[id]))
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
		"REALITY_PUBLIC": true, "REALITY_SHORT_ID": true, "DOMAIN": true,
		"CERT_DOMAIN": true, "ACME_EMAIL": true, "CORE_CHANNEL": true, "NODE_DEPLOYED": true,
		"STATS_API":      true,
		"CORE_SOURCE":    true,
		"SUB_SERVE_PORT": true, "SUB_SYNC_SECONDS": true, "SERVER_IP": true,
		"FRONT_ENABLED": true, "FRONT_APP": true, "FRONT_PORT": true,
	}
	var out []string
	for k := range c.raw {
		// Application ports are written from AppPorts, never from raw.
		if strings.HasPrefix(k, "APP_") && strings.HasSuffix(k, "_PORT") {
			continue
		}
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

// yesNo spells a flag the way the state file stores the panel's own switches.
func yesNo(b bool) string {
	if b {
		return "yes"
	}
	return "no"
}
