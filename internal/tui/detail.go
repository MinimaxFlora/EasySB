package tui

import (
	"strings"

	"charm.land/lipgloss/v2"

	"github.com/MinimaxFlora/EasySB/internal/sysinfo"
	"github.com/MinimaxFlora/EasySB/internal/theme"
)

// runtimeStatus renders a compact, left-aligned runtime summary (service, node,
// domain and listening ports) used inside the version block.
func (a *App) runtimeStatus(width int) string {
	if !a.ready {
		return a.palette.Dim(a.lang.T("loading") + "…")
	}
	s := a.status

	svcKey, svcOK := "state_unknown", false
	switch s.Service {
	case "running":
		svcKey, svcOK = "state_running", true
	case "stopped":
		svcKey = "state_stopped"
	}

	nodeKey, nodeOK := "node_not_deployed", false
	if s.Deployed {
		nodeKey, nodeOK = "node_deployed", true
	}

	domain := s.Domain
	if strings.TrimSpace(domain) == "" {
		domain = a.lang.T("not_set")
	}
	ports := enabledPorts(s.Ports)

	sep := "   "
	plain := a.lang.T("status_service") + " " + a.lang.T(svcKey) + sep +
		a.lang.T("status_node") + " " + a.lang.T(nodeKey) + sep +
		a.lang.T("status_domain") + " " + domain
	if ports != "" {
		plain += sep + a.lang.T("status_ports") + " " + ports
	}
	if lipgloss.Width(plain) > width {
		return a.palette.Value(theme.Truncate(plain, width))
	}
	svc := a.palette.State(a.lang.T(svcKey), svcOK, svcKey == "state_stopped")
	if svcKey == "state_unknown" {
		svc = a.palette.Dim(a.lang.T(svcKey))
	}
	node := a.palette.State(a.lang.T(nodeKey), nodeOK, false)
	if nodeKey == "node_not_deployed" {
		node = a.palette.Dim(a.lang.T(nodeKey))
	}
	out := a.palette.Label(a.lang.T("status_service")) + " " + svc + sep +
		a.palette.Label(a.lang.T("status_node")) + " " + node + sep +
		a.palette.Label(a.lang.T("status_domain")) + " " + a.palette.Value(domain)
	if ports != "" {
		out += sep + a.palette.Label(a.lang.T("status_ports")) + " " + a.palette.Value(ports)
	}
	return out
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
