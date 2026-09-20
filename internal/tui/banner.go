package tui

import (
	"strings"

	"charm.land/lipgloss/v2"

	"github.com/MinimaxFlora/EasySB/internal/theme"
)

func (a *App) renderBanner(width int) string {
	if width < 44 {
		width = 44
	}
	inner := width - 4

	versionTag := "v" + a.scriptVersion
	tagline := theme.Truncate(a.lang.T("banner_tagline"), inner-lipgloss.Width(versionTag)-3)
	head := a.palette.Bold(a.palette.Primary, versionTag) + "   " +
		a.palette.Colored(a.palette.Text, tagline)

	fields := [][2]string{
		{a.lang.T("banner_author"), "MinimaxFlora"},
		{a.lang.T("banner_project"), "https://github.com/MinimaxFlora/EasySB"},
		{a.lang.T("banner_core"), "https://github.com/SagerNet/sing-box"},
		{a.lang.T("banner_quote"), a.lang.Hitokoto()},
	}

	lines := []string{head, ""}
	for _, f := range fields {
		label := theme.Fit(f[0], 8)
		budget := inner - 11
		if budget < 8 {
			budget = 8
		}
		value := theme.Truncate(f[1], budget)
		lines = append(lines, a.palette.Label(label)+" : "+a.palette.Value(value))
	}
	return theme.Box("EasySB", strings.Join(lines, "\n"), width, a.palette.Border, a.palette.Primary)
}

func (a *App) renderVersions(w int) []string {
	local := a.lang.T("ver_not_installed")
	if a.status.CoreVersion != "" {
		local = a.status.CoreVersion + " [" + a.lang.T(channelKey(a.status.CoreChannel)) + "]"
	}
	pairs := [][2]string{
		{a.lang.T("ver_script"), a.scriptVersion},
		{a.lang.T("ver_local_core"), local},
		{a.lang.T("ver_stable"), "—"},
		{a.lang.T("ver_alpha"), "—"},
	}

	labelWidth := 12
	valueWidth := w - labelWidth - 5
	if valueWidth < 6 {
		valueWidth = 6
	}

	lines := make([]string, 0, len(pairs))
	for _, p := range pairs {
		label := a.palette.Label(theme.Fit(p[0], labelWidth))
		value := a.palette.Value(theme.Truncate(p[1], valueWidth))
		lines = append(lines, " "+label+" : "+value)
	}
	return lines
}

func channelKey(channel string) string {
	if channel == "alpha" {
		return "ver_channel_alpha"
	}
	return "ver_channel_stable"
}
