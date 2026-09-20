package sysinfo

import (
	"bufio"
	"context"
	"encoding/json"
	"os"
	"os/exec"
	"regexp"
	"strings"
	"time"
)

const (
	WorkDir     = "/etc/sing-box"
	ConfigJSON  = WorkDir + "/config.json"
	StateFile   = WorkDir + "/easysb.conf"
	CoreBin     = WorkDir + "/sing-box"
	ServiceName = "sing-box"
)

type Status struct {
	ScriptVersion string
	CoreVersion   string
	CoreChannel   string
	Service       string
	Autostart     string
	Domain        string
	UUID          string
	Password      string
	Hop           string
	Ports         []PortInfo
	Deployed      bool
	StateFound    bool
}

type PortInfo struct {
	Protocol string
	Port     string
	Enabled  bool
}

var protocolOrder = []struct{ key, label string }{
	{"anytls", "AnyTLS"},
	{"hysteria2", "Hysteria2"},
	{"tuic", "TUIC v5"},
	{"vless_reality", "VLESS-Reality"},
	{"vmess_ws_tls", "VMess-WS-TLS"},
}

func Collect(scriptVersion string) Status {
	st := Status{
		ScriptVersion: scriptVersion,
		Service:       "unknown",
		Autostart:     "unknown",
	}
	st.CoreVersion, st.CoreChannel = coreVersion()
	st.Service = serviceState("is-active")
	st.Autostart = serviceState("is-enabled")

	state := readState()
	st.StateFound = len(state) > 0
	st.Domain = state["DOMAIN"]
	if st.Domain == "" {
		st.Domain = state["CERT_DOMAIN"]
	}
	st.UUID = state["UUID"]
	st.Password = state["PASSWORD"]
	st.Hop = state["HY2_HOP_RANGE"]

	inbounds := readInbounds()
	if len(inbounds) > 0 {
		st.Deployed = true
		for _, p := range protocolOrder {
			port := inbounds[p.key]
			if port == "" {
				port = state[portKey(p.key)]
			}
			st.Ports = append(st.Ports, PortInfo{Protocol: p.label, Port: port, Enabled: port != ""})
		}
	} else {
		for _, p := range protocolOrder {
			port := state[portKey(p.key)]
			st.Ports = append(st.Ports, PortInfo{Protocol: p.label, Port: port, Enabled: port != ""})
		}
		if _, err := os.Stat(ConfigJSON); err == nil {
			st.Deployed = true
		}
	}
	return st
}

func portKey(proto string) string {
	return "PORT_" + strings.ToUpper(proto)
}

func coreVersion() (string, string) {
	if _, err := os.Stat(CoreBin); err != nil {
		return "", ""
	}
	out, err := run(3*time.Second, CoreBin, "version")
	if err != nil {
		return "", ""
	}
	re := regexp.MustCompile(`(?m)version\s+([^\s]+)`)
	m := re.FindStringSubmatch(out)
	if len(m) < 2 {
		return "", ""
	}
	v := m[1]
	channel := "stable"
	if strings.Contains(strings.ToLower(v), "alpha") || strings.Contains(strings.ToLower(v), "beta") || strings.Contains(strings.ToLower(v), "rc") {
		channel = "alpha"
	}
	return v, channel
}

func serviceState(verb string) string {
	if _, err := exec.LookPath("systemctl"); err != nil {
		return "unknown"
	}
	out, _ := run(3*time.Second, "systemctl", verb, ServiceName)
	out = strings.TrimSpace(out)
	if out == "" {
		return "unknown"
	}
	switch verb {
	case "is-active":
		if out == "active" {
			return "running"
		}
		return "stopped"
	default:
		if strings.HasPrefix(out, "enabled") {
			return "enabled"
		}
		return "disabled"
	}
}

func readState() map[string]string {
	result := map[string]string{}
	f, err := os.Open(StateFile)
	if err != nil {
		return result
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
		val = strings.TrimSpace(val)
		val = strings.Trim(val, `"'`)
		if key != "" {
			result[key] = val
		}
	}
	return result
}

func readInbounds() map[string]string {
	result := map[string]string{}
	data, err := os.ReadFile(ConfigJSON)
	if err != nil {
		return result
	}
	var cfg struct {
		Inbounds []struct {
			Type       string `json:"type"`
			Tag        string `json:"tag"`
			ListenPort int    `json:"listen_port"`
		} `json:"inbounds"`
	}
	if err := json.Unmarshal(data, &cfg); err != nil {
		return result
	}
	for _, in := range cfg.Inbounds {
		if in.ListenPort <= 0 {
			continue
		}
		key := normalizeType(in.Type)
		if key == "" {
			continue
		}
		result[key] = itoa(in.ListenPort)
	}
	return result
}

func normalizeType(t string) string {
	switch strings.ToLower(t) {
	case "anytls":
		return "anytls"
	case "hysteria2", "hysteria":
		return "hysteria2"
	case "tuic":
		return "tuic"
	case "vless":
		return "vless_reality"
	case "vmess":
		return "vmess_ws_tls"
	default:
		return ""
	}
}

func itoa(n int) string {
	if n == 0 {
		return "0"
	}
	neg := n < 0
	if neg {
		n = -n
	}
	var b [20]byte
	i := len(b)
	for n > 0 {
		i--
		b[i] = byte('0' + n%10)
		n /= 10
	}
	if neg {
		i--
		b[i] = '-'
	}
	return string(b[i:])
}

func run(timeout time.Duration, name string, args ...string) (string, error) {
	ctx, cancel := context.WithTimeout(context.Background(), timeout)
	defer cancel()
	cmd := exec.CommandContext(ctx, name, args...)
	cmd.Env = append(os.Environ(), "LC_ALL=C")
	out, err := cmd.CombinedOutput()
	return string(out), err
}
