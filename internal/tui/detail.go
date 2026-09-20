package tui

import (
	"strings"

	"github.com/MinimaxFlora/EasySB/internal/sysinfo"
	"github.com/MinimaxFlora/EasySB/internal/theme"
)

// statusSummary renders a single compact, left-aligned status line shown under
// the version block. It keeps the live state visible without a separate panel.
func (a *App) statusSummary(width int) []string {
	if !a.ready {
		return []string{" " + a.palette.Dim(a.lang.T("loading")+"…")}
	}
	s := a.status

	svc := a.lang.T("state_unknown")
	switch s.Service {
	case "running":
		svc = a.lang.T("state_running")
	case "stopped":
		svc = a.lang.T("state_stopped")
	}

	core := a.lang.T("ver_not_installed")
	if s.CoreVersion != "" {
		core = s.CoreVersion + " [" + a.lang.T(channelKey(s.CoreChannel)) + "]"
	}

	domain := s.Domain
	if strings.TrimSpace(domain) == "" {
		domain = a.lang.T("not_set")
	}

	node := a.lang.T("node_not_deployed")
	if s.Deployed {
		node = a.lang.T("node_deployed")
	}

	sep := "   "
	plain := a.lang.T("status_service") + " " + svc + sep +
		a.lang.T("status_core") + " " + core + sep +
		a.lang.T("status_domain") + " " + domain + sep +
		a.lang.T("status_node") + " " + node
	if ports := enabledPorts(s.Ports); ports != "" {
		plain += sep + a.lang.T("status_ports") + " " + ports
	}
	return []string{" " + a.palette.Value(theme.Truncate(plain, width-1))}
}

// enabledPorts joins the listening ports of enabled protocols for the status
// board.
func enabledPorts(ports []sysinfo.PortInfo) string {
	var out []string
	for _, p := range ports {
		if p.Enabled && p.Port != "" {
			out = append(out, p.Port)
		}
	}
	return strings.Join(out, " ")
}
