package tui

import (
	"strings"
	"testing"

	tea "charm.land/bubbletea/v2"
	"charm.land/lipgloss/v2"

	"github.com/MinimaxFlora/EasySB/internal/i18n"
	"github.com/MinimaxFlora/EasySB/internal/icons"
	"github.com/MinimaxFlora/EasySB/internal/theme"
)

func sampleLinks() []linkItem {
	return []linkItem{
		{label: "sing-box", meta: "example.com:8443", desc: "json", value: "https://example.com:8443/singbox/aaaa"},
		{label: "mihomo", meta: "example.com:8443", desc: "yaml", value: "https://example.com:8443/mihomo/aaaa"},
		{label: "v2ray", meta: "example.com:8443", desc: "base64", value: "https://example.com:8443/v2ray/aaaa"},
	}
}

func TestLinksViewHidesValues(t *testing.T) {
	l := newLinksModel("订阅链接", sampleLinks())
	view := l.View(100, 40, theme.Dark(), i18n.Chinese, icons.Plain())
	for _, item := range l.items {
		if strings.Contains(view, item.value) {
			t.Fatalf("view leaked value %q", item.value)
		}
	}
	if !strings.Contains(view, "example.com:8443") {
		t.Fatal("view should show the short host:port meta")
	}
}

func TestLinksClickCopiesCard(t *testing.T) {
	l := newLinksModel("t", sampleLinks())
	l.View(100, 40, theme.Dark(), i18n.Chinese, icons.Plain())
	if len(l.boxes) != 3 {
		t.Fatalf("expected 3 hit boxes, got %d", len(l.boxes))
	}
	b := l.boxes[2]
	if cmd := l.handleClick(b.x+1, b.y+1); cmd == nil {
		t.Fatal("clicking a card should return a clipboard command")
	}
	if l.copied != 2 {
		t.Fatalf("expected card 2 copied, got %d", l.copied)
	}
}

func TestLinksClickOutsideIsNoop(t *testing.T) {
	l := newLinksModel("t", sampleLinks())
	l.View(100, 40, theme.Dark(), i18n.Chinese, icons.Plain())
	if cmd := l.handleClick(0, 0); cmd != nil {
		t.Fatal("clicking the header should not copy")
	}
	if l.copied != -1 {
		t.Fatalf("copied should stay unset, got %d", l.copied)
	}
}

func TestLinksNumberKeyCopies(t *testing.T) {
	l := newLinksModel("t", sampleLinks())
	l.View(100, 40, theme.Dark(), i18n.Chinese, icons.Plain())
	cmd, done := l.handleKey(press('2'), i18n.Chinese)
	if done {
		t.Fatal("number key must not close the panel")
	}
	if cmd == nil || l.copied != 1 {
		t.Fatalf("digit 2 should copy card 1, copied=%d", l.copied)
	}
}

func TestLinksEnterCopiesCursor(t *testing.T) {
	l := newLinksModel("t", sampleLinks())
	l.View(100, 40, theme.Dark(), i18n.Chinese, icons.Plain())
	l.move(2)
	cmd, done := l.handleKey(press(tea.KeyEnter), i18n.Chinese)
	if done || cmd == nil || l.copied != 2 {
		t.Fatalf("enter should copy the cursor card, copied=%d done=%v", l.copied, done)
	}
}

func TestLinksEscCloses(t *testing.T) {
	l := newLinksModel("t", sampleLinks())
	l.View(100, 40, theme.Dark(), i18n.Chinese, icons.Plain())
	if _, done := l.handleKey(press(tea.KeyEsc), i18n.Chinese); !done {
		t.Fatal("esc should close the panel")
	}
}

func TestLinksMouseToggle(t *testing.T) {
	l := newLinksModel("t", sampleLinks())
	if !l.mouse {
		t.Fatal("panel should start with mouse capture on")
	}
	l.handleKey(press('m'), i18n.Chinese)
	if l.mouse {
		t.Fatal("m should release the mouse")
	}
}

func TestGridDims(t *testing.T) {
	cases := []struct {
		width, count, cols int
	}{
		{100, 3, 3},
		{80, 3, 2},
		{60, 3, 2},
		{44, 3, 1},
		{100, 1, 1},
	}
	for _, c := range cases {
		cols, cardW := gridDims(c.width, c.count)
		if cols != c.cols {
			t.Errorf("gridDims(%d,%d) cols=%d, want %d", c.width, c.count, cols, c.cols)
		}
		if cardW < 8 {
			t.Errorf("gridDims(%d,%d) cardW=%d too small", c.width, c.count, cardW)
		}
	}
}

func TestLinksViewFitsWidth(t *testing.T) {
	for _, width := range []int{44, 60, 80, 100, 140} {
		l := newLinksModel("t", sampleLinks())
		view := l.View(width, 40, theme.Dark(), i18n.Chinese, icons.Plain())
		if width == 100 {
			t.Logf("width 100 layout:\n%s", view)
		}
		for _, line := range strings.Split(view, "\n") {
			if lipgloss.Width(line) > width {
				t.Fatalf("width %d: line wider than viewport: %q", width, line)
			}
		}
	}
}
