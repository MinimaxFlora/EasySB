package tui

import (
	"strings"
	"testing"

	tea "charm.land/bubbletea/v2"

	"github.com/MinimaxFlora/EasySB/internal/i18n"
	"github.com/MinimaxFlora/EasySB/internal/sysinfo"
)

func press(code rune) tea.KeyPressMsg {
	return tea.KeyPressMsg(tea.Key{Code: code})
}

func newTestApp(t *testing.T) *App {
	t.Helper()
	a := New("test", i18n.Chinese)
	m, _ := a.Update(tea.WindowSizeMsg{Width: 100, Height: 34})
	a = m.(*App)
	m, _ = a.Update(statusMsg(sysinfo.Status{
		Service:     "running",
		CoreVersion: "1.15.0-alpha.6",
		CoreChannel: "alpha",
		Autostart:   "enabled",
		Domain:      "example.com",
		Deployed:    true,
		Ports:       []sysinfo.PortInfo{{Protocol: "AnyTLS", Port: "8000", Enabled: true}},
	}))
	return m.(*App)
}

func TestDashboardRendersStatus(t *testing.T) {
	a := newTestApp(t)
	v := a.View()
	for _, want := range []string{"EasySB", "example.com", "1.15.0-alpha.6"} {
		if !strings.Contains(v.Content, want) {
			t.Fatalf("view missing %q", want)
		}
	}
}

func TestRecursiveNavigation(t *testing.T) {
	a := newTestApp(t)

	m, _ := a.Update(press(tea.KeyDown))
	a = m.(*App)
	if got := a.selected().id; got != "node" {
		t.Fatalf("expected node selected, got %s", got)
	}

	m, _ = a.Update(press(tea.KeyEnter))
	a = m.(*App)
	if a.current().id != "node" {
		t.Fatalf("expected node menu, got %s", a.current().id)
	}

	m, _ = a.Update(press(tea.KeyDown))
	a = m.(*App)
	m, _ = a.Update(press(tea.KeyEnter))
	a = m.(*App)
	if a.current().id != "params" {
		t.Fatalf("expected params menu, got %s", a.current().id)
	}

	for i := 0; i < 3; i++ {
		m, _ = a.Update(press(tea.KeyDown))
		a = m.(*App)
	}
	m, _ = a.Update(press(tea.KeyEnter))
	a = m.(*App)
	if a.current().id != "ports" {
		t.Fatalf("expected ports menu, got %s", a.current().id)
	}

	m, _ = a.Update(press(tea.KeyEscape))
	a = m.(*App)
	m, _ = a.Update(press(tea.KeyEscape))
	a = m.(*App)
	if a.current().id != "node" {
		t.Fatalf("expected to return to node menu, got %s", a.current().id)
	}
}

func TestNavRowReturnsToParent(t *testing.T) {
	a := newTestApp(t)
	m, _ := a.Update(press(tea.KeyDown))
	a = m.(*App)
	m, _ = a.Update(press(tea.KeyEnter))
	a = m.(*App)
	if a.current().id != "node" {
		t.Fatalf("expected node menu, got %s", a.current().id)
	}

	// node menu has two nodes plus the trailing navigation row.
	for i := 0; i < 2; i++ {
		m, _ = a.Update(press(tea.KeyDown))
		a = m.(*App)
	}
	if !a.onNavRow() {
		t.Fatalf("expected cursor on nav row")
	}
	if !strings.Contains(a.View().Content, i18n.Chinese.T("nav_back")) {
		t.Fatalf("nav row label missing from view")
	}

	m, _ = a.Update(press(tea.KeyEnter))
	a = m.(*App)
	if a.current().id != "root" {
		t.Fatalf("expected to return to root, got %s", a.current().id)
	}
}

func TestLanguageToggle(t *testing.T) {
	a := newTestApp(t)
	m, _ := a.Update(press('l'))
	a = m.(*App)
	if a.lang != i18n.English {
		t.Fatalf("expected English, got %s", a.lang)
	}
	if !strings.Contains(a.View().Content, "Main menu") {
		t.Fatalf("english menu title missing")
	}
}

func TestActionableStubSetsToast(t *testing.T) {
	a := newTestApp(t)
	for i := 0; i < 5; i++ {
		m, _ := a.Update(press(tea.KeyDown))
		a = m.(*App)
	}
	if got := a.selected().id; got != "script-update" {
		t.Fatalf("expected script-update selected, got %s", got)
	}
	m, _ := a.Update(press(tea.KeyEnter))
	a = m.(*App)
	if a.toast == "" {
		t.Fatalf("expected a toast after stub action")
	}
}
