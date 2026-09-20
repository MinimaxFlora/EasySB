package tui

import (
	"charm.land/lipgloss/v2"

	"github.com/MinimaxFlora/EasySB/internal/theme"
)

// headerTitle renders the product name, version and tagline.
func (a *App) headerTitle(w int) string {
	versionTag := "v" + a.scriptVersion
	tagline := theme.Truncate(a.lang.T("banner_tagline"), maxInt(4, w-lipgloss.Width(versionTag)-12))
	return " " + a.palette.Bold(a.palette.Primary, "EasySB") + " " +
		a.palette.Colored(a.palette.Accent, versionTag) + "  " + a.palette.Dim(tagline)
}

// headerAuthor renders the author and project line.
func (a *App) headerAuthor() string {
	return " " + a.palette.Label(a.lang.T("banner_author")) + " " + a.palette.Value("MinimaxFlora") +
		a.palette.Dim("  ·  ") + a.palette.Label(a.lang.T("banner_project")) + " " +
		a.palette.Value("github.com/MinimaxFlora/EasySB")
}

// headerQuote renders the daily quote chosen when the app started.
func (a *App) headerQuote(w int) string {
	return " " + a.palette.Label(a.lang.T("banner_quote")) + " " +
		a.palette.Value(theme.Truncate(a.quote, maxInt(8, w-12)))
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
