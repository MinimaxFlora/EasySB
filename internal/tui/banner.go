package tui

import (
	"charm.land/lipgloss/v2"

	"github.com/MinimaxFlora/EasySB/internal/theme"
)

// renderHeader prints the compact title and author block shown above the menu:
// version + tagline, author/project links and the daily quote.
func (a *App) renderHeader(w int) []string {
	versionTag := "v" + a.scriptVersion
	head := a.palette.Bold(a.palette.Primary, "EasySB") + " " +
		a.palette.Colored(a.palette.Accent, versionTag) + "  " +
		a.palette.Dim(theme.Truncate(a.lang.T("banner_tagline"), maxInt(4, w-lipgloss.Width(versionTag)-12)))

	meta := a.palette.Label(a.lang.T("banner_author")) + " " + a.palette.Value("MinimaxFlora") +
		a.palette.Dim("  ·  ") + a.palette.Label(a.lang.T("banner_project")) + " " +
		a.palette.Value("github.com/MinimaxFlora/EasySB")

	quote := a.palette.Label(a.lang.T("banner_quote")) + " " +
		a.palette.Value(theme.Truncate(a.lang.Hitokoto(), maxInt(8, w-12)))

	return []string{" " + head, " " + meta, " " + quote}
}

func channelKey(channel string) string {
	if channel == "alpha" {
		return "ver_channel_alpha"
	}
	return "ver_channel_stable"
}

func maxInt(a, b int) int {
	if a > b {
		return a
	}
	return b
}
