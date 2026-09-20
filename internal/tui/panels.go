package tui

import (
	"strings"

	"github.com/MinimaxFlora/EasySB/internal/theme"
)

// subPanel renders a bordered card of the given outer width. It is used for the
// device and node cards nested inside the main dashboard box.
func (a *App) subPanel(title string, lines []string, width int) []string {
	if len(lines) == 0 {
		lines = []string{""}
	}
	box := theme.Box(title, strings.Join(lines, "\n"), width, a.palette.Border, a.palette.Accent)
	return strings.Split(box, "\n")
}

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

// deviceLines renders the host description shown in the device card.
func (a *App) deviceLines(width int) []string {
	if !a.ready {
		return []string{" " + a.palette.Dim(a.lang.T("loading")+"…")}
	}
	s := a.status
	sep := "   "
	plain := a.lang.T("device_host") + " " + a.panelValue(s.Hostname) + sep +
		a.lang.T("device_os") + " " + a.panelValue(s.OS) + sep +
		a.lang.T("device_arch") + " " + a.panelValue(s.Arch) + sep +
		a.lang.T("device_kernel") + " " + a.panelValue(s.Kernel) + sep +
		a.lang.T("device_memory") + " " + a.panelValue(s.Memory)
	return []string{" " + a.palette.Value(theme.Truncate(plain, width-5))}
}

// nodeLines renders the credential summary shown in the node card.
func (a *App) nodeLines(width int) []string {
	if !a.ready {
		return []string{" " + a.palette.Dim(a.lang.T("loading")+"…")}
	}
	s := a.status
	sep := "   "
	plain := a.lang.T("node_uuid") + " " + a.panelValue(s.UUID) + sep +
		a.lang.T("node_password") + " " + a.panelValue(s.Password) + sep +
		a.lang.T("node_hop") + " " + a.panelValue(s.Hop) + sep +
		a.lang.T("node_ports") + " " + a.panelValue(enabledPorts(s.Ports))
	return []string{" " + a.palette.Value(theme.Truncate(plain, width-5))}
}
