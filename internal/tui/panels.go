package tui

import (
	"strings"

	"charm.land/lipgloss/v2"

	"github.com/MinimaxFlora/EasySB/internal/state"
	"github.com/MinimaxFlora/EasySB/internal/theme"
)

// hintBox renders the key hints as their own box below the dashboard.
func (a *App) hintBox(width int) []string {
	box := theme.Box(a.lang.T("panel_hints"), a.statusBar(width-4), width, a.palette.Border, a.palette.Primary)
	return strings.Split(box, "\n")
}

func (a *App) panelValue(v string) string {
	if strings.TrimSpace(v) == "" {
		return a.lang.T("not_set")
	}
	return v
}

// deviceSection renders the host description: public IP, hostname and OS on the
// left, architecture, kernel and timezone on the right.
func (a *App) deviceSection(width int) []string {
	s := a.status
	if !a.ready {
		return []string{"  " + a.palette.Dim(a.lang.T("loading")+"…")}
	}
	rows := []string{
		a.twoCols(width, "device_public_ip", s.PublicIP, "device_arch", s.Arch),
		a.twoCols(width, "device_host", s.Hostname, "device_kernel", s.Kernel),
		a.twoCols(width, "device_os", s.OS, "device_timezone", s.Timezone),
	}
	return append([]string{a.sectionTitle("panel_device")}, rows...)
}

// nodeSection renders every node parameter, shown inside node management.
func (a *App) nodeSection(width int) []string {
	cfg := state.Load()
	rows := []string{
		a.kvRow(a.lang.T("node_uuid"), cfg.UUID, width),
		a.kvRow(a.lang.T("node_password"), cfg.Password, width),
		a.kvRow(a.lang.T("param_hop"), cfg.HopRange, width),
		a.kvRow(a.lang.T("param_ports"), portSummary(cfg), width),
		a.kvRow(a.lang.T("param_sni"), cfg.RealitySNI, width),
		a.kvRow(a.lang.T("node_privkey"), cfg.RealityPriv, width),
		a.kvRow(a.lang.T("node_shortid"), cfg.RealitySID, width),
	}
	return append([]string{a.sectionTitle("panel_node")}, rows...)
}

func (a *App) sectionTitle(key string) string {
	return "  " + a.palette.Bold(a.palette.Primary, a.lang.T(key))
}

// twoCols renders a two-column key/value row, padding the left column so the
// right one lines up across rows.
func (a *App) twoCols(width int, lKey, lVal, rKey, rVal string) string {
	col := (width - 4) / 2
	lLbl := a.lang.T(lKey)
	rLbl := a.lang.T(rKey)
	lv := theme.Truncate(a.panelValue(lVal), maxInt(4, col-lipgloss.Width(lLbl)-2))
	rv := theme.Truncate(a.panelValue(rVal), maxInt(4, width-4-col-lipgloss.Width(rLbl)-2))
	left := theme.Pad(a.palette.Label(lLbl)+" "+a.palette.Value(lv), col)
	right := a.palette.Label(rLbl) + " " + a.palette.Value(rv)
	return "  " + left + "  " + right
}

// kvRow renders a single aligned label/value row.
func (a *App) kvRow(label, value string, width int) string {
	const labelWidth = 18
	plain := theme.Truncate(label, labelWidth)
	pad := labelWidth - lipgloss.Width(plain)
	if pad < 1 {
		pad = 1
	}
	val := theme.Truncate(a.panelValue(value), maxInt(4, width-2-labelWidth-2))
	return "  " + a.palette.Label(plain) + strings.Repeat(" ", pad) + a.palette.Value(val)
}

// portSummary lists the enabled protocol ports for the node card.
func portSummary(cfg state.Config) string {
	var out []string
	for _, k := range state.Keys {
		if cfg.Enabled[k] && cfg.Ports[k] != "" {
			out = append(out, state.Labels[k]+":"+cfg.Ports[k])
		}
	}
	return strings.Join(out, "  ")
}
