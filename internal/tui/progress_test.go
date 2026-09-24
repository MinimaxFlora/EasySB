package tui

import (
	"context"
	"fmt"
	"strconv"
	"strings"
	"testing"

	tea "charm.land/bubbletea/v2"
	"charm.land/lipgloss/v2"

	"github.com/MinimaxFlora/EasySB/internal/i18n"
	"github.com/MinimaxFlora/EasySB/internal/icons"
	"github.com/MinimaxFlora/EasySB/internal/theme"
)

func TestProgressDoneScrolls(t *testing.T) {
	p := newProgress("qr", func(context.Context, func(string)) error { return nil })
	p.resize(80, 30)
	for i := 0; i < 200; i++ {
		p.logs = append(p.logs, "line")
	}
	p.refresh()
	p.done = true

	before := p.vp.YOffset()
	if before == 0 {
		t.Fatalf("expected finished task to start scrolled to the bottom, got offset 0")
	}
	if _, closed := p.handleKey(press(tea.KeyUp), i18n.Chinese); closed {
		t.Fatalf("up key should scroll, not close the task")
	}
	if got := p.vp.YOffset(); got >= before {
		t.Fatalf("up key did not scroll: before=%d after=%d", before, got)
	}
	if _, closed := p.handleKey(press(tea.KeyEnter), i18n.Chinese); !closed {
		t.Fatalf("enter should close a finished task")
	}
}

func TestProgressFollowsTailWhileRunning(t *testing.T) {
	p := newProgress("t", func(context.Context, func(string)) error { return nil })
	p.resize(80, 20)
	for i := 0; i < 100; i++ {
		p.appendLog("x")
	}
	if !p.vp.AtBottom() {
		t.Fatalf("running task should keep following the log tail")
	}
}

func TestProgressArrowsScrollFinishedLog(t *testing.T) {
	p := newProgress("qr", func(context.Context, func(string)) error { return nil })
	p.resize(80, 20)
	for i := 0; i < 100; i++ {
		p.appendLog("line")
	}
	p.done = true

	before := p.vp.YOffset()
	if before == 0 {
		t.Fatalf("expected finished task to start at the bottom")
	}
	if _, closed := p.handleKey(press(tea.KeyUp), i18n.Chinese); closed {
		t.Fatal("arrow up should scroll, not close the task")
	}
	up := p.vp.YOffset()
	if up >= before {
		t.Fatalf("arrow up did not scroll: before=%d after=%d", before, up)
	}
	p.handleKey(press(tea.KeyDown), i18n.Chinese)
	if got := p.vp.YOffset(); got <= up {
		t.Fatalf("arrow down did not scroll back: up=%d down=%d", up, got)
	}
}

func TestProgressCopiesLogToClipboard(t *testing.T) {
	p := newProgress("url", func(context.Context, func(string)) error { return nil })
	p.resize(80, 20)
	p.appendLog("sing-box: https://example.com/a")
	p.appendLog("v2rayN: https://example.com/c")
	p.done = true

	cmd, closed := p.handleKey(press('c'), i18n.Chinese)
	if closed {
		t.Fatal("copy must not close the task")
	}
	if cmd == nil {
		t.Fatal("copy must return a clipboard command")
	}
	payload := fmt.Sprint(cmd())
	for _, want := range []string{"https://example.com/a", "https://example.com/c"} {
		if !strings.Contains(payload, want) {
			t.Fatalf("clipboard payload %q is missing %q", payload, want)
		}
	}
}

func TestProgressIgnoresMouseToggleKey(t *testing.T) {
	p := newProgress("t", func(context.Context, func(string)) error { return nil })
	p.resize(80, 20)
	if _, closed := p.handleKey(press('m'), i18n.Chinese); closed {
		t.Fatal("a stray key must not close the task")
	}
}

func TestProgressFitsTerminal(t *testing.T) {
	// The task screen is what every action lands on, so it has to fit the terminal
	// at any height the same way the dashboard does: no frame taller than the
	// window, and no line wider than it.
	for _, size := range [][2]int{{40, 6}, {80, 9}, {80, 12}, {100, 16}, {100, 22}, {100, 24}, {120, 40}, {140, 60}} {
		w, h := size[0], size[1]
		p := newProgress("订阅服务", func(context.Context, func(string)) error { return nil })
		for i := 0; i < 40; i++ {
			p.appendLog("log line " + strconv.Itoa(i) + " with some length to it")
		}
		for _, done := range []bool{false, true} {
			p.done = done
			out := p.View(w, h, "host  service  node", theme.DefaultSkin().Style(true), i18n.Chinese, icons.Symbols())
			lines := strings.Split(out, "\n")
			if len(lines) != h {
				t.Fatalf("%dx%d done=%v: drew %d lines, want %d", w, h, done, len(lines), h)
			}
			for i, line := range lines {
				if got := lipgloss.Width(line); got > w {
					t.Fatalf("%dx%d done=%v: line %d is %d wide", w, h, done, i, got)
				}
			}
		}
	}
}

func TestProgressNoCopyHidesAndIgnoresCopy(t *testing.T) {
	p := newProgress("qr", func(context.Context, func(string)) error { return nil })
	p.noCopy = true
	p.resize(80, 20)
	p.appendLog("QR")
	p.done = true

	if cmd, closed := p.handleKey(press('c'), i18n.Chinese); cmd != nil || closed {
		t.Fatalf("a picture task must ignore copy, cmd=%v closed=%v", cmd != nil, closed)
	}
	view := p.View(80, 20, "", theme.DefaultSkin().Style(true), i18n.Chinese, icons.Symbols())
	if strings.Contains(view, i18n.Chinese.T("task_copy")) {
		t.Fatal("the hint must not offer copy on a picture task")
	}
	if !strings.Contains(view, i18n.Chinese.T("hint_quit")) {
		t.Fatal("the hint should offer Q to quit")
	}
}
