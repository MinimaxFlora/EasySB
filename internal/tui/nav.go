package tui

import (
	"strings"

	"github.com/MinimaxFlora/EasySB/internal/theme"
)

// The grouped navigation lives here. It is no longer drawn as a left column: every
// page of the panel uses the same two-box frame (the page's 看板 over its entries), and
// a section is left with Esc the way a submenu is. sectionID and padLines are still on
// the hot path; navRows, navColumn and renderNav are kept for reference and can be
// dropped with the skin grouping they read (theme.Metrics.Groups) once the removal is
// confirmed.

// sectionID is the root entry the panel is currently inside, or "" on the main
// menu. The section is recorded when a root entry is entered; a stack that was
// assembled another way (tests, restored state) still resolves through the menu
// ids, which repeat their root node id.
func (a *App) sectionID() string {
	if a.section != "" {
		return a.section
	}
	if len(a.stack) < 2 {
		return ""
	}
	for _, n := range a.stack[0].nodes {
		for i := 1; i < len(a.stack); i++ {
			if a.stack[i].id == n.id {
				return n.id
			}
		}
	}
	return ""
}

// padLines clips every line to w columns and fills the column to h rows.
func padLines(lines []string, w, h int) []string {
	out := make([]string, 0, h)
	for _, line := range lines {
		if len(out) == h {
			break
		}
		out = append(out, theme.Pad(theme.Truncate(line, w), w))
	}
	for len(out) < h {
		out = append(out, strings.Repeat(" ", w))
	}
	return out
}
