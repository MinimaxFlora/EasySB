package tui

import (
	"github.com/MinimaxFlora/EasySB/internal/theme"
)

// headerTagline renders the enlarged product tagline shown as the first line of
// the dashboard body.
func (a *App) headerTagline(w int) string {
	text := theme.Truncate(a.lang.T("banner_tagline"), maxInt(8, w-4))
	return "  " + a.palette.Bold(a.palette.Primary, text)
}

// headerAuthor renders the author and project line.
func (a *App) headerAuthor() string {
	return "  " + a.palette.Label(a.lang.T("banner_author")) + " " + a.palette.Value("MinimaxFlora") +
		a.palette.Dim("  ·  ") + a.palette.Label(a.lang.T("banner_project")) + " " +
		a.palette.Value("github.com/MinimaxFlora/EasySB")
}

// versionLines renders the version block: the app version, the installed core
// with its channel tag, and a compact runtime summary.
func (a *App) versionLines(width int) []string {
	core := a.lang.T("ver_not_installed")
	tag := ""
	if a.status.CoreVersion != "" {
		core = a.status.CoreVersion
		tag = "  " + a.channelTag()
	}
	label := func(key string) string {
		return "  " + theme.Pad(a.palette.Label(a.lang.T(key)), 16)
	}
	line1 := label("ver_easysb") + a.palette.Value(a.scriptVersion)
	line2 := label("ver_core") + a.palette.Value(core) + tag
	line3 := label("ver_runtime") + a.runtimeStatus(width-18)
	return []string{line1, line2, line3}
}

// channelTag renders a colored stable/test badge for the installed core.
func (a *App) channelTag() string {
	if a.status.CoreChannel == "alpha" {
		return a.palette.Colored(a.palette.Warn, "["+a.lang.T("ver_channel_test")+"]")
	}
	return a.palette.Colored(a.palette.OK, "["+a.lang.T("ver_channel_stable")+"]")
}

// headerQuote renders the daily quote chosen when the app started.
func (a *App) headerQuote(w int) string {
	return "  " + a.palette.Label(a.lang.T("banner_quote")) + " " +
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
