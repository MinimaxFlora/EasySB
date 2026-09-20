package tui

import (
	"strings"

	"charm.land/lipgloss/v2"

	"github.com/MinimaxFlora/EasySB/internal/state"
	"github.com/MinimaxFlora/EasySB/internal/theme"
)

// keyColumn is the display width reserved for a key before its value, keeping
// the two columns of a two-column row aligned.
const keyColumn = 13

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

func (a *App) sectionTitle(key string) string {
	return "  " + a.palette.Bold(a.palette.Primary, a.lang.T(key))
}

// overviewRows renders the runtime overview: version and core, service and node
// state, then domain and listening ports.
func (a *App) overviewRows(width int) []string {
	s := a.status

	corePlain := a.lang.T("ver_not_installed")
	coreStyle := func(v string) string { return a.palette.Dim(v) }
	if s.CoreVersion != "" {
		corePlain = s.CoreVersion + " [" + a.lang.T(channelTagKey(s.CoreChannel)) + "]"
		if s.CoreChannel == "alpha" {
			coreStyle = func(v string) string { return a.palette.Colored(a.palette.Warn, v) }
		} else {
			coreStyle = func(v string) string { return a.palette.Colored(a.palette.OK, v) }
		}
	}

	svcKey, svcOK, svcWarn, svcKnown := "state_unknown", false, false, false
	switch s.Service {
	case "running":
		svcKey, svcOK, svcKnown = "state_running", true, true
	case "stopped":
		svcKey, svcWarn, svcKnown = "state_stopped", true, true
	}
	svcStyle := func(v string) string { return a.stateValue(v, svcOK, svcWarn, svcKnown) }

	nodeKey, nodeOK, nodeKnown := "node_not_deployed", false, false
	if s.Deployed {
		nodeKey, nodeOK, nodeKnown = "node_deployed", true, true
	}
	nodeStyle := func(v string) string { return a.stateValue(v, nodeOK, false, nodeKnown) }

	// The EasySB version shares the stable-channel green so the two version
	// readouts look consistent.
	versionStyle := func(v string) string { return a.palette.Colored(a.palette.OK, v) }

	return []string{
		a.styledTwoCols(width, a.lang.T("ov_version"), a.scriptVersion, versionStyle,
			a.lang.T("ov_core"), corePlain, coreStyle),
		a.styledTwoCols(width,
			a.lang.T("ov_service"), "● "+a.lang.T(svcKey), svcStyle,
			a.lang.T("ov_node"), "● "+a.lang.T(nodeKey), nodeStyle),
		a.styledTwoCols(width, a.lang.T("status_domain"), a.panelValue(s.Domain), a.palette.Value,
			a.lang.T("status_ports"), a.panelValue(enabledPorts(s.Ports)), a.palette.Value),
	}
}

func channelTagKey(channel string) string {
	if channel == "alpha" {
		return "ver_channel_test"
	}
	return "ver_channel_stable"
}

// stateValue renders a colored status token, dimming it while the state is not
// yet known.
func (a *App) stateValue(text string, ok, warn, known bool) string {
	if !known {
		return a.palette.Dim(text)
	}
	return a.palette.State(text, ok, warn)
}

// deviceSection renders the host description: public IP, hostname and OS on the
// left, architecture, kernel and timezone on the right.
func (a *App) deviceSection(width int) []string {
	s := a.status
	if !a.ready {
		return []string{"  " + a.palette.Dim(a.lang.T("loading")+"…")}
	}
	return []string{
		a.sectionTitle("panel_device"),
		a.twoCols(width, "device_public_ip", s.PublicIP, "device_arch", s.Arch),
		a.twoCols(width, "device_host", s.Hostname, "device_kernel", s.Kernel),
		a.twoCols(width, "device_os", s.OS, "device_timezone", s.Timezone),
	}
}

// nodeSection renders every node parameter, shown inside node management.
func (a *App) nodeSection(width int) []string {
	cfg := state.Load()
	return []string{
		a.sectionTitle("panel_node"),
		a.kvRow(a.lang.T("node_uuid"), cfg.UUID, width),
		a.kvRow(a.lang.T("node_password"), cfg.Password, width),
		a.kvRow(a.lang.T("param_hop"), cfg.HopRange, width),
		a.kvRow(a.lang.T("param_ports"), portSummary(cfg), width),
		a.kvRow(a.lang.T("param_sni"), cfg.RealitySNI, width),
		a.kvRow(a.lang.T("node_privkey"), cfg.RealityPriv, width),
		a.kvRow(a.lang.T("node_shortid"), cfg.RealitySID, width),
	}
}

// styledTwoCols aligns two cells into a two-column row, truncating each value to
// whatever the terminal width allows before applying its style.
func (a *App) styledTwoCols(width int, lLabel, lText string, lStyle func(string) string, rLabel, rText string, rStyle func(string) string) string {
	col := (width - 4) / 2
	labelW := keyColumn
	if max := col - 2; labelW > max {
		labelW = max
	}
	if max := width - 4 - col; labelW > max {
		labelW = max
	}
	if labelW < 1 {
		labelW = 1
	}
	lValue := theme.Truncate(lText, maxInt(0, col-labelW-1))
	rValue := theme.Truncate(rText, maxInt(0, width-4-col-labelW))
	lLabel = theme.Truncate(lLabel, labelW)
	rLabel = theme.Truncate(rLabel, labelW)
	left := theme.Pad(a.palette.Label(theme.Pad(lLabel, labelW))+lStyle(lValue), col)
	right := a.palette.Label(theme.Pad(rLabel, labelW)) + rStyle(rValue)
	return "  " + left + "  " + right
}

// twoCols renders a two-column key/value row, padding the left column so the
// right one lines up across rows.
func (a *App) twoCols(width int, lKey, lVal, rKey, rVal string) string {
	return a.styledTwoCols(width, a.lang.T(lKey), a.panelValue(lVal), a.palette.Value,
		a.lang.T(rKey), a.panelValue(rVal), a.palette.Value)
}

// kvRow renders a single aligned label/value row.
func (a *App) kvRow(label, value string, width int) string {
	labelWidth := keyColumn + 5
	if labelWidth > width-4 {
		labelWidth = maxInt(1, width-4)
	}
	plain := theme.Truncate(label, labelWidth)
	pad := labelWidth - lipgloss.Width(plain)
	if pad < 1 {
		pad = 1
	}
	val := theme.Truncate(a.panelValue(value), maxInt(0, width-2-labelWidth-1))
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
