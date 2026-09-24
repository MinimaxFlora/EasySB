package tui

import (
	"strings"

	"github.com/MinimaxFlora/EasySB/internal/theme"
)

// The left navigation is the panel's map: it lists every root entry, grouped the
// way the current skin groups them, and marks the section the panel is standing
// in. It is a view over the root menu, never a separate state, so the cursor and
// the stack stay the only things that decide what is on screen.

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

// navRow is one line of the navigation column: either a group heading or a root
// entry with its position in the root menu.
type navRow struct {
	heading string
	node    *node
	index   int
}

// navRows applies the skin's grouping to the root entries. Entries a skin does
// not mention are collected under a trailing group, so adding a screen can never
// make it unreachable from the navigation.
func (a *App) navRows() []navRow {
	root := a.stack[0]
	byID := make(map[string]*node, len(root.nodes))
	for _, n := range root.nodes {
		byID[n.id] = n
	}
	placed := make(map[string]bool, len(root.nodes))
	var rows []navRow
	for _, g := range a.style().Met.Groups {
		var group []navRow
		for _, id := range g.IDs {
			n, ok := byID[id]
			if !ok || placed[id] {
				continue
			}
			placed[id] = true
			group = append(group, navRow{node: n, index: indexOfNode(root, id)})
		}
		if len(group) == 0 {
			continue
		}
		rows = append(rows, navRow{heading: a.lang.T(g.TitleKey)})
		rows = append(rows, group...)
	}
	var rest []navRow
	for i, n := range root.nodes {
		if !placed[n.id] {
			rest = append(rest, navRow{node: n, index: i})
		}
	}
	if len(rest) > 0 {
		rows = append(rows, navRow{heading: a.lang.T("nav_group_more")})
		rows = append(rows, rest...)
	}
	return rows
}

func indexOfNode(m *menu, id string) int {
	for i, n := range m.nodes {
		if n.id == id {
			return i
		}
	}
	return 0
}

// navColumn renders the navigation in exactly w columns and h rows: the menu
// title, the grouped entries, and the description of the entry the cursor is on.
// Group headings are dropped before entries, and the column is then windowed
// around the current section, so the entry the operator cares about stays
// visible on a short terminal.
func (a *App) navColumn(w, h int) []string {
	if h <= 0 {
		return nil
	}
	s := a.style()
	head := make([]string, 0, 2)
	head = append(head, theme.Pad(s.Bold(s.Primary, theme.Truncate(a.current().title(a.lang), w)), w))

	rows := a.navRows()
	for _, headings := range []bool{true, false} {
		lines, cur := a.renderNav(rows, w, headings)
		budget := h - len(head)
		if len(lines) <= budget {
			out := append(append([]string{}, head...), lines...)
			return padLines(out, w, h)
		}
		if !headings {
			lines = windowAround(lines, cur, budget)
			out := append(append([]string{}, head...), lines...)
			return padLines(out, w, h)
		}
	}
	return padLines(head, w, h)
}

// renderNav draws the navigation rows and reports the line the current section
// ended up on, which is what windowAround keeps on screen.
func (a *App) renderNav(rows []navRow, w int, headings bool) ([]string, int) {
	s := a.style()
	atRoot := len(a.stack) == 1
	cur := a.sectionID()
	out := make([]string, 0, len(rows))
	curLine := -1
	for _, r := range rows {
		if r.node == nil {
			if !headings {
				continue
			}
			out = append(out, s.Faint(theme.Truncate(r.heading, w)))
			continue
		}
		label := a.nodeLabel(r.node)
		isCursor := atRoot && r.index == a.index
		isSection := cur != "" && r.node.id == cur
		switch {
		case isCursor:
			out = append(out, s.SelectedRow(theme.Pad("▌ "+theme.Truncate(label, w-2), w)))
		case isSection:
			out = append(out, s.Accented("▌ "+theme.Truncate(label, w-2)))
		default:
			out = append(out, s.Colored(s.Muted, theme.Pad("  "+theme.Truncate(label, w-2), w)))
		}
		if isCursor || isSection {
			curLine = len(out) - 1
		}
	}
	return out, curLine
}

// windowAround keeps the line of interest inside h rows, preferring to show what
// comes after it when the terminal is short.
func windowAround(lines []string, focus, h int) []string {
	if len(lines) <= h || h <= 0 {
		return lines
	}
	if focus < 0 {
		return lines[:h]
	}
	start := focus - h/2
	if start > len(lines)-h {
		start = len(lines) - h
	}
	if start < 0 {
		start = 0
	}
	return lines[start : start+h]
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
