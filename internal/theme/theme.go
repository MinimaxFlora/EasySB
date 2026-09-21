package theme

import (
	"image/color"
	"strings"

	"charm.land/lipgloss/v2"
)

type Palette struct {
	Primary color.Color
	Accent  color.Color
	OK      color.Color
	Warn    color.Color
	Err     color.Color
	Text    color.Color
	Muted   color.Color
	Border  color.Color
	SelBg   color.Color
	SelFg   color.Color
}

func Dark() Palette {
	return Palette{
		Primary: lipgloss.Color("#22d3ee"),
		Accent:  lipgloss.Color("#3b82f6"),
		OK:      lipgloss.Color("#34d399"),
		Warn:    lipgloss.Color("#fbbf24"),
		Err:     lipgloss.Color("#f87171"),
		Text:    lipgloss.Color("#e5e7eb"),
		Muted:   lipgloss.Color("#7c8aa0"),
		Border:  lipgloss.Color("#155e75"),
		SelBg:   lipgloss.Color("#164e63"),
		SelFg:   lipgloss.Color("#f0fdff"),
	}
}

// Light is the palette for terminals with a light background. The hues match
// Dark, but every color is darkened so it stays readable on white: the dark
// palette's pastel accents and near-white body text all but disappear there.
func Light() Palette {
	return Palette{
		Primary: lipgloss.Color("#0e7490"),
		Accent:  lipgloss.Color("#1d4ed8"),
		OK:      lipgloss.Color("#047857"),
		Warn:    lipgloss.Color("#b45309"),
		Err:     lipgloss.Color("#b91c1c"),
		Text:    lipgloss.Color("#1f2937"),
		Muted:   lipgloss.Color("#4b5563"),
		Border:  lipgloss.Color("#0891b2"),
		SelBg:   lipgloss.Color("#bae6fd"),
		SelFg:   lipgloss.Color("#0c4a6e"),
	}
}

func (p Palette) Bold(c color.Color, s string) string {
	return lipgloss.NewStyle().Bold(true).Foreground(c).Render(s)
}

func (p Palette) Colored(c color.Color, s string) string {
	return lipgloss.NewStyle().Foreground(c).Render(s)
}

func (p Palette) Dim(s string) string {
	return lipgloss.NewStyle().Foreground(p.Muted).Render(s)
}

func (p Palette) Label(s string) string {
	return lipgloss.NewStyle().Foreground(p.Accent).Bold(true).Render(s)
}

func (p Palette) Value(s string) string {
	return lipgloss.NewStyle().Foreground(p.Text).Render(s)
}

// SelectedRow paints one full menu row as the selection cursor. It spans the
// whole row, label and trailing description included, so the highlight is not
// limited to the label column.
func (p Palette) SelectedRow(s string) string {
	return lipgloss.NewStyle().Bold(true).Foreground(p.SelFg).Background(p.SelBg).Render(s)
}

func (p Palette) State(s string, ok bool, warn bool) string {
	switch {
	case warn:
		return lipgloss.NewStyle().Bold(true).Foreground(p.Warn).Render(s)
	case ok:
		return lipgloss.NewStyle().Bold(true).Foreground(p.OK).Render(s)
	default:
		return lipgloss.NewStyle().Bold(true).Foreground(p.Err).Render(s)
	}
}

func Truncate(s string, w int) string {
	if w <= 0 {
		return ""
	}
	if lipgloss.Width(s) <= w {
		return s
	}
	var b strings.Builder
	cur := 0
	for _, r := range s {
		rw := lipgloss.Width(string(r))
		if cur+rw > w-1 {
			break
		}
		b.WriteRune(r)
		cur += rw
	}
	return b.String() + "…"
}

func Pad(s string, w int) string {
	if w <= 0 {
		return s
	}
	pad := w - lipgloss.Width(s)
	if pad <= 0 {
		return s
	}
	return s + strings.Repeat(" ", pad)
}

func Box(title, content string, width int, border color.Color, titleColor color.Color) string {
	if width < 8 {
		width = 8
	}
	title = Truncate(title, width-6)
	tw := lipgloss.Width(title)
	fill := width - 5 - tw
	if fill < 0 {
		fill = 0
	}
	top := lipgloss.NewStyle().Foreground(border).Render("╭─ ") +
		lipgloss.NewStyle().Bold(true).Foreground(titleColor).Render(title) +
		lipgloss.NewStyle().Foreground(border).Render(" "+strings.Repeat("─", fill)+"╮")

	inner := width - 4
	lines := strings.Split(content, "\n")
	var body strings.Builder
	for _, ln := range lines {
		body.WriteString(lipgloss.NewStyle().Foreground(border).Render("│ "))
		body.WriteString(Pad(ln, inner))
		body.WriteString(lipgloss.NewStyle().Foreground(border).Render(" │"))
		body.WriteString("\n")
	}
	bottom := lipgloss.NewStyle().Foreground(border).Render("╰" + strings.Repeat("─", width-2) + "╯")
	return top + "\n" + body.String() + bottom
}

// Center places s in the middle of a field of the given width, measuring styled
// text with lipgloss so ANSI sequences do not skew the padding.
func Center(s string, width int) string {
	if width <= 0 {
		return s
	}
	pad := width - lipgloss.Width(s)
	if pad <= 0 {
		return s
	}
	return strings.Repeat(" ", pad/2) + s
}

// TopRule draws the opening border of a panel.
func TopRule(width int, c color.Color) string {
	if width < 2 {
		return ""
	}
	return lipgloss.NewStyle().Foreground(c).Render("╭" + strings.Repeat("─", width-2) + "╮")
}

// BottomRule draws the closing border of a panel.
func BottomRule(width int, c color.Color) string {
	if width < 2 {
		return ""
	}
	return lipgloss.NewStyle().Foreground(c).Render("╰" + strings.Repeat("─", width-2) + "╯")
}

// SectionRule draws a full-width divider between two sections of a panel.
func SectionRule(width int, c color.Color) string {
	if width < 2 {
		return ""
	}
	return lipgloss.NewStyle().Foreground(c).Render("├" + strings.Repeat("─", width-2) + "┤")
}

// FrameRule draws a horizontal rule that joins the panel's two side borders.
func FrameRule(width int, c color.Color) string {
	if width < 2 {
		return ""
	}
	return lipgloss.NewStyle().Foreground(c).Render("│" + strings.Repeat("─", width-2) + "│")
}

// FrameLine wraps one body row in the panel's side borders, padding it to the
// inner width so the right border stays aligned.
func FrameLine(s string, width int, c color.Color) string {
	inner := width - 4
	if inner < 0 {
		inner = 0
	}
	return lipgloss.NewStyle().Foreground(c).Render("│ ") + Pad(s, inner) + lipgloss.NewStyle().Foreground(c).Render(" │")
}
