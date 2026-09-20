package tui

import (
	"context"
	"testing"

	tea "charm.land/bubbletea/v2"
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
	if _, closed := p.handleKey(press(tea.KeyUp)); closed {
		t.Fatalf("up key should scroll, not close the task")
	}
	if got := p.vp.YOffset(); got >= before {
		t.Fatalf("up key did not scroll: before=%d after=%d", before, got)
	}
	if _, closed := p.handleKey(press(tea.KeyEnter)); !closed {
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
