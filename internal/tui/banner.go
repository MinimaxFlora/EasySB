package tui

import (
	"charm.land/lipgloss/v2"

	"github.com/MinimaxFlora/EasySB/internal/theme"
)

const (
	bannerAuthor = "MinimaxFlora"
	bannerRepo   = "MinimaxFlora/EasySB"
	bannerBlog   = "www.kejizero.xyz"
	bannerDocs   = "sb.kejizero.xyz"
)

// logoGlyphs holds the "ANSI Shadow" block letters used for the EasySB banner.
// Every glyph is six rows tall and eight columns wide so the letters tile.
var logoGlyphs = map[rune][6]string{
	'E': {
		"███████╗",
		"██╔════╝",
		"█████╗  ",
		"██╔══╝  ",
		"███████╗",
		"╚══════╝",
	},
	'A': {
		" █████╗ ",
		"██╔══██╗",
		"███████║",
		"██╔══██║",
		"██║  ██║",
		"╚═╝  ╚═╝",
	},
	'S': {
		"███████╗",
		"██╔════╝",
		"███████╗",
		"╚════██║",
		"███████║",
		"╚══════╝",
	},
	'Y': {
		"██╗   ██╗",
		"╚██╗ ██╔╝",
		" ╚████╔╝ ",
		"  ╚██╔╝  ",
		"   ██║   ",
		"   ╚═╝   ",
	},
	'B': {
		"██████╗ ",
		"██╔══██╗",
		"██████╔╝",
		"██╔══██╗",
		"██████╔╝",
		"╚═════╝ ",
	},
}

// logoLines renders the block-letter EasySB wordmark centered in the panel. It
// returns nil when the terminal is too narrow to hold it.
func (a *App) logoLines(inner int) []string {
	rows := make([]string, 6)
	for _, ch := range "EASYSB" {
		glyph, ok := logoGlyphs[ch]
		if !ok {
			return nil
		}
		for r := 0; r < 6; r++ {
			rows[r] += glyph[r]
		}
	}
	if lipgloss.Width(rows[0]) > inner {
		return nil
	}
	out := make([]string, len(rows))
	for r, row := range rows {
		out[r] = theme.Center(a.palette.Bold(a.palette.Primary, row), inner)
	}
	return out
}

// taglineLines renders the centered product tagline followed by a hairline rule
// that separates the header from the rest of the dashboard.
func (a *App) taglineLines(inner int) []string {
	text := theme.Center(a.palette.Bold(a.palette.Primary, theme.Truncate(a.lang.T("banner_tagline"), inner)), inner)
	return []string{text, "  " + theme.Rule(maxInt(1, inner-4), a.palette.Border) + "  "}
}

// contactLines renders the centered-ish author, project, blog and docs block.
func (a *App) contactLines() []string {
	row := func(key, value string) string {
		return "  " + theme.Pad(a.palette.Label(a.lang.T(key)), 9) + a.palette.Value(value)
	}
	return []string{
		row("banner_author", bannerAuthor),
		row("banner_project", bannerRepo),
		row("banner_blog", bannerBlog),
		row("banner_docs", bannerDocs),
	}
}

// quoteLine renders the frozen daily quote framed by full-width quotation marks.
func (a *App) quoteLine(inner int) string {
	return theme.Center(a.palette.Dim("“"+a.quote+"”"), inner)
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
