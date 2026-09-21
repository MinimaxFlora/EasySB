package tui

import (
	"strconv"
	"strings"

	tea "charm.land/bubbletea/v2"

	"github.com/MinimaxFlora/EasySB/internal/i18n"
	"github.com/MinimaxFlora/EasySB/internal/icons"
	"github.com/MinimaxFlora/EasySB/internal/theme"
)

// linkCardHeight is the number of terminal rows one card occupies. Cards are
// fixed height so the mouse hit boxes stay stable across renders.
const linkCardHeight = 5

// linkCardGap is the blank gap between two card columns in cells.
const linkCardGap = 2

// linkCardMin is the narrowest card that still fits a client name plus a copy
// chip. It drives the number of columns chosen for a given width.
const linkCardMin = 26

// linkItem is one copyable entry shown as a card. The URL/value is never
// rendered; only label, meta and desc are visible, and the value is what a
// click or key press puts on the clipboard.
type linkItem struct {
	label string
	meta  string
	desc  string
	value string
}

// linkBox is the on-screen rectangle of a card, used for mouse hit testing.
type linkBox struct {
	x, y, w, h int
	index      int
}

// linksModel is a grid of copyable cards, used for subscription endpoints and
// share links. Unlike the task log it never prints the full URL: clicking a card
// copies its value through OSC52.
type linksModel struct {
	title  string
	items  []linkItem
	boxes  []linkBox
	cursor int
	copied int
	cols   int
	cardW  int
	mouse  bool
}

func newLinksModel(title string, items []linkItem) *linksModel {
	return &linksModel{title: title, items: items, copied: -1, mouse: true}
}

// copy stores text on the system clipboard and remembers which card produced it.
func (l *linksModel) copy(index int) tea.Cmd {
	if index < 0 || index >= len(l.items) {
		return nil
	}
	l.copied = index
	return tea.SetClipboard(l.items[index].value)
}

// copyAll puts every value on the clipboard, one per line.
func (l *linksModel) copyAll() tea.Cmd {
	values := make([]string, 0, len(l.items))
	for _, item := range l.items {
		values = append(values, item.value)
	}
	l.copied = -1
	return tea.SetClipboard(strings.Join(values, "\n"))
}

// gridDims picks the column count and card width for a viewport.
func gridDims(width, count int) (int, int) {
	cols := 3
	if width < cols*linkCardMin+(cols-1)*linkCardGap {
		cols = 2
	}
	if width < 2*linkCardMin+linkCardGap {
		cols = 1
	}
	if count > 0 && cols > count {
		cols = count
	}
	if cols < 1 {
		cols = 1
	}
	cardW := (width - (cols-1)*linkCardGap) / cols
	if cardW < 8 {
		cardW = 8
	}
	return cols, cardW
}

// handleKey processes a key press. The bool reports whether the panel should
// close.
func (l *linksModel) handleKey(msg tea.KeyPressMsg, lang i18n.Lang) (tea.Cmd, bool) {
	key := strings.ToLower(msg.String())
	switch key {
	case "m":
		l.mouse = !l.mouse
		return nil, false
	case "esc", "q", "backspace":
		return nil, true
	case "enter":
		return l.copy(l.cursor), false
	case "c":
		return l.copyAll(), false
	case "left":
		l.move(-1)
		return nil, false
	case "right":
		l.move(1)
		return nil, false
	case "up":
		l.move(-l.rowStep())
		return nil, false
	case "down":
		l.move(l.rowStep())
		return nil, false
	}
	if n, err := strconv.Atoi(key); err == nil && n >= 1 && n <= len(l.items) {
		l.cursor = n - 1
		return l.copy(n - 1), false
	}
	return nil, false
}

// rowStep is one grid row in cursor steps. It falls back to 1 before the first
// render has measured the column count.
func (l *linksModel) rowStep() int {
	if l.cols < 1 {
		return 1
	}
	return l.cols
}

// move shifts the cursor by d cards and clamps it to the item range.
func (l *linksModel) move(d int) {
	if len(l.items) == 0 {
		return
	}
	l.cursor += d
	if l.cursor < 0 {
		l.cursor = 0
	}
	if l.cursor >= len(l.items) {
		l.cursor = len(l.items) - 1
	}
}

// handleClick copies the card under the pointer, if any.
func (l *linksModel) handleClick(x, y int) tea.Cmd {
	for _, b := range l.boxes {
		if x >= b.x && x < b.x+b.w && y >= b.y && y < b.y+b.h {
			l.cursor = b.index
			return l.copy(b.index)
		}
	}
	return nil
}

// card renders one card. The value is deliberately absent from the content.
func (l *linksModel) card(item linkItem, index, width int, pal theme.Palette, lang i18n.Lang, ic icons.Set) string {
	inner := width - 4
	meta := pal.Value(theme.Truncate(item.meta, inner))
	desc := pal.Dim(theme.Truncate(item.desc, inner))

	chip := ic.Link + " " + lang.T("links_copy")
	if l.copied == index {
		chip = ic.OK + " " + lang.T("links_copied")
	}
	var chipLine string
	if l.cursor == index {
		chipLine = pal.SelectedRow(" " + theme.Truncate(chip, inner-2) + " ")
	} else {
		chipLine = pal.Colored(pal.Primary, theme.Truncate(chip, inner))
	}

	border := pal.Border
	if l.cursor == index {
		border = pal.Primary
	}
	content := meta + "\n" + desc + "\n" + chipLine
	return theme.Box(item.label, content, width, border, pal.Primary)
}

// render lays the cards out in a grid and records their hit boxes.
func (l *linksModel) render(width int, pal theme.Palette, lang i18n.Lang, ic icons.Set) string {
	cols, cardW := gridDims(width, len(l.items))
	l.cols, l.cardW = cols, cardW

	const startY = 2 // header line plus a blank line

	header := pal.Bold(pal.Primary, " "+ic.Link+" "+theme.Truncate(l.title, width-6))

	boxes := l.boxes[:0]
	var out []string

	rows := (len(l.items) + cols - 1) / cols
	for row := 0; row < rows; row++ {
		y := startY + row*(linkCardHeight+1)
		cards := make([]string, cols)
		for col := 0; col < cols; col++ {
			index := row*cols + col
			if index < len(l.items) {
				cards[col] = l.card(l.items[index], index, cardW, pal, lang, ic)
			} else {
				cards[col] = blankCard(cardW)
			}
		}
		cardLines := make([][]string, cols)
		for col := range cards {
			cardLines[col] = strings.Split(cards[col], "\n")
		}
		for line := 0; line < linkCardHeight; line++ {
			parts := make([]string, 0, cols)
			for col := 0; col < cols; col++ {
				parts = append(parts, cardLines[col][line])
			}
			out = append(out, strings.Join(parts, strings.Repeat(" ", linkCardGap)))
		}
		for col := 0; col < cols; col++ {
			index := row*cols + col
			if index >= len(l.items) {
				break
			}
			boxes = append(boxes, linkBox{x: col * (cardW + linkCardGap), y: y, w: cardW, h: linkCardHeight, index: index})
		}
		if row != rows-1 {
			out = append(out, "")
		}
	}
	l.boxes = boxes

	return header + "\n\n" + strings.Join(out, "\n") + "\n" + l.footer(width, pal, lang, ic)
}

// blankCard keeps empty grid cells the same width as a real card.
func blankCard(width int) string {
	line := strings.Repeat(" ", width)
	return strings.Join([]string{line, line, line, line, line}, "\n")
}

func (l *linksModel) footer(width int, pal theme.Palette, lang i18n.Lang, ic icons.Set) string {
	if l.copied >= 0 && l.copied < len(l.items) {
		status := pal.Colored(pal.OK, " "+ic.OK+" "+lang.T("links_copied")+": ") + l.items[l.copied].label
		return theme.Truncate(status, width)
	}
	return pal.Dim(theme.Truncate(" "+lang.T("links_hint"), width))
}

func (l *linksModel) View(w, h int, pal theme.Palette, lang i18n.Lang, ic icons.Set) string {
	width := w
	if width < 32 {
		width = 32
	}
	return l.render(width, pal, lang, ic)
}
