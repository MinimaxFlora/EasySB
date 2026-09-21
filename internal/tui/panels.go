package tui

import (
	"fmt"
	"strings"
	"time"

	"charm.land/lipgloss/v2"

	"github.com/MinimaxFlora/EasySB/internal/i18n"
	"github.com/MinimaxFlora/EasySB/internal/state"
	"github.com/MinimaxFlora/EasySB/internal/theme"
)

// keyColumn is the display width reserved for a key before its value, keeping
// the two columns of a two-column row aligned.
const keyColumn = 13

// hintRows is the height of the pinned hint box, or zero when the terminal is
// too short to spare the rows. Every screen shares this so the box keeps one
// position and size.
func hintRows(h int) int {
	if h >= 14 {
		return 3
	}
	return 0
}

// hintBox renders the key hints as their own box below the frame. hint is the
// already-styled left side; the language code stays pinned to the right.
func (a *App) hintBox(hint string, width int) []string {
	return hintBoxFor(a.palette, a.lang, hint, width)
}

// hintLine pads an already-styled hint to width and pins the language code to
// the right edge, so every screen shows it at the same place.
func (a *App) hintLine(hint string, width int) string {
	return hintLineFor(a.palette, a.lang, hint, width)
}

// hintLineFor is hintLine for callers that only hold a palette and language.
func hintLineFor(pal theme.Palette, lang i18n.Lang, hint string, width int) string {
	right := pal.Label(lang.Code() + " ")
	rightW := lipgloss.Width(right)
	availLeft := width - rightW - 1
	if availLeft < 1 {
		availLeft = 1
	}
	left := " " + theme.Truncate(hint, maxInt(0, availLeft-1))
	gap := width - lipgloss.Width(left) - rightW
	if gap < 1 {
		gap = 1
	}
	return left + strings.Repeat(" ", gap) + right
}

// hintBoxFor is hintBox for callers that only hold a palette and language.
func hintBoxFor(pal theme.Palette, lang i18n.Lang, hint string, width int) []string {
	box := theme.Box(lang.T("panel_hints"), hintLineFor(pal, lang, hint, width-4), width, pal.Border, pal.Primary)
	return strings.Split(box, "\n")
}

// panelWidth is the shared panel width: the terminal width capped at 100 so
// every screen lines up with the main dashboard.
func panelWidth(w int) int {
	if w <= 0 {
		w = 96
	}
	if w > 100 {
		w = 100
	}
	if w < 24 {
		w = 24
	}
	return w
}

// panelBodyHeight is the number of inner content rows shared by every screen:
// the terminal height minus the borders and the bottom hints (box or line).
func panelBodyHeight(h int) int {
	chrome := hintRows(h)
	if chrome == 0 {
		chrome = 1
	}
	b := h - chrome - 2
	if b < 1 {
		b = 1
	}
	return b
}

// framePanel draws inner body lines inside the shared panel frame and pins the
// hint to the bottom. The body is clipped or padded to the frame's fixed
// height, so the panel is exactly the same size as the main dashboard.
func framePanel(pal theme.Palette, lang i18n.Lang, w, h int, body []string, hint string) string {
	rows := hintRows(h)
	bodyH := panelBodyHeight(h)
	out := make([]string, 0, h)
	out = append(out, theme.TopRule(w, pal.Border))
	for i := 0; i < bodyH; i++ {
		s := ""
		if i < len(body) {
			s = body[i]
		}
		out = append(out, theme.FrameLine(s, w, pal.Border))
	}
	out = append(out, theme.BottomRule(w, pal.Border))
	if rows > 0 {
		out = append(out, hintBoxFor(pal, lang, hint, w)...)
	} else {
		out = append(out, " "+theme.Truncate(hint, maxInt(0, w-2)))
	}
	return strings.Join(out, "\n")
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

// overviewRows renders the runtime overview: service and node state, version
// and core, then domain and listening ports.
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
		a.styledTwoCols(width,
			a.lang.T("ov_service"), "● "+a.lang.T(svcKey), svcStyle,
			a.lang.T("ov_node"), "● "+a.lang.T(nodeKey), nodeStyle),
		a.styledTwoCols(width, a.lang.T("ov_version"), a.scriptVersion, versionStyle,
			a.lang.T("ov_core"), corePlain, coreStyle),
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

// deviceSection renders the host description: local IPv4/IPv6, swap and uptime,
// CPU and load, memory and disk, then hostname, kernel, OS and timezone.
func (a *App) deviceSection(width int) []string {
	s := a.status
	if !a.ready {
		return []string{"  " + a.palette.Dim(a.lang.T("loading")+"…")}
	}
	return []string{
		a.sectionTitle("panel_device"),
		a.twoCols(width, "device_local_ipv4", s.LocalIPv4, "device_local_ipv6", s.LocalIPv6),
		a.twoCols(width, "device_swap", usageCell(s.SwapTotal, s.SwapFree), "device_uptime", humanDuration(s.Uptime)),
		a.twoCols(width, "device_cpu", a.cpuSummary(), "device_load", s.LoadAvg),
		a.twoCols(width, "device_memory", usageCell(s.MemTotal, s.MemAvail), "device_disk", usageCell(s.DiskTotal, s.DiskFree)),
		a.twoCols(width, "device_host", s.Hostname, "device_kernel", s.Kernel),
		a.twoCols(width, "device_os", s.OS, "device_timezone", s.Timezone),
	}
}

// cpuSummary renders the processor core count, e.g. "8 cores".
func (a *App) cpuSummary() string {
	if a.status.CPUCores <= 0 {
		return ""
	}
	return fmt.Sprintf("%d %s", a.status.CPUCores, a.lang.T("unit_cores"))
}

// usageCell formats a used/total pair with its usage percentage, or an empty
// string when the total is unknown.
func usageCell(total, free uint64) string {
	if total == 0 {
		return ""
	}
	if free > total {
		free = total
	}
	used := total - free
	return fmt.Sprintf("%s / %s (%d%%)", humanBytes(used), humanBytes(total), used*100/total)
}

// humanBytes renders a byte count with a binary unit and one decimal.
func humanBytes(n uint64) string {
	const unit = 1024
	if n < unit {
		return fmt.Sprintf("%d B", n)
	}
	units := []string{"KiB", "MiB", "GiB", "TiB", "PiB"}
	value := float64(n)
	i := -1
	for value >= unit && i < len(units)-1 {
		value /= unit
		i++
	}
	return fmt.Sprintf("%.1f %s", value, units[i])
}

// humanDuration renders an uptime as "3d 4h 5m", dropping leading units that
// are zero. Anything below a minute reads as "0m".
func humanDuration(d time.Duration) string {
	if d <= 0 {
		return ""
	}
	days := int(d / (24 * time.Hour))
	d -= time.Duration(days) * 24 * time.Hour
	hours := int(d / time.Hour)
	d -= time.Duration(hours) * time.Hour
	mins := int(d / time.Minute)
	var b strings.Builder
	if days > 0 {
		fmt.Fprintf(&b, "%dd ", days)
	}
	if days > 0 || hours > 0 {
		fmt.Fprintf(&b, "%dh ", hours)
	}
	fmt.Fprintf(&b, "%dm", mins)
	return b.String()
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
