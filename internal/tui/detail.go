package tui

import (
	"strings"

	"charm.land/lipgloss/v2"

	"github.com/MinimaxFlora/EasySB/internal/i18n"
	"github.com/MinimaxFlora/EasySB/internal/theme"
)

func (a *App) statusLines(inner int) []string {
	if !a.ready {
		return []string{a.palette.Dim(a.lang.T("loading") + "…")}
	}
	lw := 8
	if a.lang == i18n.English {
		lw = 13
	}
	s := a.status
	var lines []string

	svcText, svcKind := a.lang.T("state_unknown"), "muted"
	switch s.Service {
	case "running":
		svcText, svcKind = a.iconSet.Running+" "+a.lang.T("state_running"), "ok"
	case "stopped":
		svcText, svcKind = a.iconSet.Stopped+" "+a.lang.T("state_stopped"), "err"
	}
	lines = append(lines, a.statusRow(a.lang.T("status_service"), svcText, svcKind, lw, inner))

	core, coreKind := a.lang.T("ver_not_installed"), "muted"
	if s.CoreVersion != "" {
		core = s.CoreVersion + " [" + a.lang.T(channelKey(s.CoreChannel)) + "]"
		coreKind = "ok"
	}
	lines = append(lines, a.statusRow(a.lang.T("status_core"), core, coreKind, lw, inner))

	autoText, autoKind := a.lang.T("state_unknown"), "muted"
	switch s.Autostart {
	case "enabled":
		autoText, autoKind = a.iconSet.Enabled+" "+a.lang.T("state_enabled"), "ok"
	case "disabled":
		autoText, autoKind = a.iconSet.Disabled+" "+a.lang.T("state_disabled"), "muted"
	}
	lines = append(lines, a.statusRow(a.lang.T("status_autostart"), autoText, autoKind, lw, inner))

	lines = append(lines, a.statusRow(a.lang.T("status_ports"), a.portsText(), a.portsKind(), lw, inner))
	lines = append(lines, a.statusRow(a.lang.T("status_domain"), a.valueOr(s.Domain), a.valueKind(s.Domain), lw, inner))
	lines = append(lines, a.statusRow(a.lang.T("status_node"), a.nodeText(), a.nodeKind(), lw, inner))

	if n := a.selected(); n != nil {
		lines = append(lines, "")
		lines = append(lines, theme.Rule(inner, a.palette.Border))
		icon := ""
		if n.icon != nil {
			icon = n.icon(a.iconSet) + " "
		}
		lines = append(lines, a.palette.Bold(a.palette.Primary, theme.Truncate(icon+n.label(a.lang), inner)))
		for _, l := range wrapText(n.desc(a.lang), inner) {
			lines = append(lines, a.palette.Dim(l))
		}
	}
	return lines
}

func (a *App) statusRow(label, text, kind string, lw, inner int) string {
	budget := inner - lw - 1
	if budget < 4 {
		budget = 4
	}
	return a.palette.Label(theme.Fit(label, lw)) + " " + a.badge(theme.Truncate(text, budget), kind)
}

func (a *App) badge(text, kind string) string {
	switch kind {
	case "ok":
		return a.palette.Colored(a.palette.OK, text)
	case "warn":
		return a.palette.Colored(a.palette.Warn, text)
	case "err":
		return a.palette.Colored(a.palette.Err, text)
	default:
		return a.palette.Colored(a.palette.Muted, text)
	}
}

func (a *App) portsText() string {
	var parts []string
	for _, p := range a.status.Ports {
		if p.Enabled && p.Port != "" {
			parts = append(parts, p.Port)
		}
	}
	if len(parts) == 0 {
		return a.lang.T("not_set")
	}
	return strings.Join(parts, " · ")
}

func (a *App) portsKind() string {
	for _, p := range a.status.Ports {
		if p.Enabled && p.Port != "" {
			return "ok"
		}
	}
	return "muted"
}

func (a *App) valueOr(v string) string {
	if strings.TrimSpace(v) == "" {
		return a.lang.T("not_set")
	}
	return v
}

func (a *App) valueKind(v string) string {
	if strings.TrimSpace(v) == "" {
		return "muted"
	}
	return "ok"
}

func (a *App) nodeText() string {
	if a.status.Deployed {
		return a.iconSet.OK + " " + a.lang.T("node_deployed")
	}
	return a.lang.T("node_not_deployed")
}

func (a *App) nodeKind() string {
	if a.status.Deployed {
		return "ok"
	}
	return "muted"
}

func wrapText(s string, width int) []string {
	if width <= 0 {
		return []string{s}
	}
	var lines []string
	cur := ""
	curWidth := 0
	for _, r := range s {
		rw := lipgloss.Width(string(r))
		if curWidth+rw > width {
			lines = append(lines, cur)
			cur = ""
			curWidth = 0
		}
		cur += string(r)
		curWidth += rw
	}
	if cur != "" {
		lines = append(lines, cur)
	}
	if len(lines) == 0 {
		lines = []string{""}
	}
	return lines
}
