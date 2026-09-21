package tui

import (
	"context"
	"errors"
	"image/color"
	"strings"
	"testing"

	tea "charm.land/bubbletea/v2"
	"charm.land/lipgloss/v2"

	"github.com/MinimaxFlora/EasySB/internal/i18n"
	"github.com/MinimaxFlora/EasySB/internal/state"
	"github.com/MinimaxFlora/EasySB/internal/sysinfo"
	"github.com/MinimaxFlora/EasySB/internal/theme"
)

func press(code rune) tea.KeyPressMsg {
	return tea.KeyPressMsg(tea.Key{Code: code})
}

func typeRune(r rune) tea.KeyPressMsg {
	return tea.KeyPressMsg(tea.Key{Code: r, Text: string(r)})
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

func TestDashboardFitsTerminal(t *testing.T) {
	// The inline renderer cannot erase lines that scrolled off the top, so the
	// boxed dashboard must never be taller than the terminal. This exercises the
	// size where the menu has to scroll itself.
	for _, h := range []int{9, 10, 12, 14, 15, 16, 18, 20, 24, 30, 40, 60} {
		a := New("test", i18n.Chinese)
		a.width, a.height = 100, h
		a.sized = true
		a.status = sysinfo.Collect("test")
		a.ready = true
		if lines := strings.Count(a.dashboard(), "\n") + 1; lines > h {
			t.Fatalf("height %d: dashboard drew %d lines", h, lines)
		}
		// The node card is taller than the device card, so exercise it too.
		a.push(buildNode())
		if lines := strings.Count(a.dashboard(), "\n") + 1; lines > h {
			t.Fatalf("height %d: node dashboard drew %d lines", h, lines)
		}
	}
}

func TestMenuViewportKeepsCursorVisible(t *testing.T) {
	a := New("test", i18n.Chinese)
	a.width, a.height = 100, 10
	a.sized = true
	a.status = sysinfo.Collect("test")
	a.ready = true
	for i := range a.current().nodes {
		a.index = i
		frame := a.dashboard()
		if !strings.Contains(frame, a.current().nodes[i].label(i18n.Chinese)) {
			t.Fatalf("frame at index %d hides the selected row:\n%s", i, frame)
		}
	}
}

func TestDashboardRendersStatus(t *testing.T) {
	a := newTestApp(t)
	v := a.View()
	for _, want := range []string{i18n.Chinese.T("banner_tagline"), "example.com", "1.15.0-alpha.6"} {
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

	// node menu: deploy, protocols, params -> params is the third row.
	for i := 0; i < 2; i++ {
		m, _ = a.Update(press(tea.KeyDown))
		a = m.(*App)
	}
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

	// node menu has three nodes plus the trailing navigation row.
	for i := 0; i < 3; i++ {
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

func TestRootMenuHasNoNav(t *testing.T) {
	a := newTestApp(t)
	if a.hasNavRow() {
		t.Fatalf("root menu should not show a navigation row")
	}
	if got := len(a.current().nodes); got != 7 {
		t.Fatalf("root should have 7 entries, got %d", got)
	}
	var hasUninstall bool
	for _, n := range a.current().nodes {
		if n.id == "uninstall" {
			hasUninstall = true
		}
	}
	if !hasUninstall {
		t.Fatalf("uninstall should be in the root menu")
	}
	view := a.View().Content
	for _, want := range []string{i18n.Chinese.T("menu_script_update"), i18n.Chinese.T("menu_uninstall")} {
		if !strings.Contains(view, want) {
			t.Fatalf("root menu missing %q:\n%s", want, view)
		}
	}
	if strings.Contains(view, "[0]") {
		t.Fatalf("root menu should not render a [0] row")
	}
}

func TestKernelMenuEntries(t *testing.T) {
	a := newTestApp(t)
	a.push(buildKernel())
	want := []string{"kernel-install-stable", "kernel-install-alpha", "kernel-switch", "kernel-update"}
	if got := len(a.current().nodes); got != len(want) {
		t.Fatalf("kernel menu has %d entries, want %d", got, len(want))
	}
	for i, id := range want {
		if got := a.current().nodes[i].id; got != id {
			t.Fatalf("kernel entry %d = %s, want %s", i, got, id)
		}
	}
	if !a.hasNavRow() {
		t.Fatalf("kernel menu should show a navigation row")
	}
	view := a.View().Content
	for _, label := range []string{"安装正式版内核", "安装测试版内核", "切换内核", "更新内核（仅更新当前通道）", i18n.Chinese.T("nav_back")} {
		if !strings.Contains(view, label) {
			t.Fatalf("kernel menu view missing %q:\n%s", label, view)
		}
	}
	m, _ := a.Update(press('0'))
	a = m.(*App)
	if !a.onNavRow() {
		t.Fatalf("digit 0 should select the navigation row in a submenu")
	}
	if a.current().id != "kernel" {
		t.Fatalf("expected kernel submenu, got %s", a.current().id)
	}
}

func TestNumberedMenuAndDigitSelection(t *testing.T) {
	a := newTestApp(t)
	if !a.View().AltScreen {
		t.Fatalf("dashboard should render fullscreen so the screen is cleared")
	}
	if !strings.Contains(a.View().Content, i18n.Chinese.T("svc_title")) {
		t.Fatalf("service entry should render its label")
	}
	m, _ := a.Update(press('5'))
	a = m.(*App)
	if got := a.selected().id; got != "service" {
		t.Fatalf("digit 5 should select service, got %s", got)
	}
	m, _ = a.Update(press(tea.KeyEnter))
	a = m.(*App)
	m, _ = a.Update(press('0'))
	a = m.(*App)
	if !a.onNavRow() {
		t.Fatalf("digit 0 should select the navigation row")
	}
}

func TestFormSubmit(t *testing.T) {
	a := newTestApp(t)
	var got string
	a.openForm("UUID", "enter value", "abc", "", func(a *App, v string) (tea.Cmd, error) {
		got = v
		return nil, nil
	})

	for _, r := range "def" {
		m, _ := a.Update(typeRune(r))
		a = m.(*App)
	}
	m, _ := a.Update(press(tea.KeyEnter))
	a = m.(*App)

	if got != "abcdef" {
		t.Fatalf("submitted %q, want %q", got, "abcdef")
	}
	if a.form != nil {
		t.Fatal("form should close after successful submit")
	}
}

func TestFormValidationKeepsOpen(t *testing.T) {
	a := newTestApp(t)
	a.openForm("title", "prompt", "", "", func(a *App, v string) (tea.Cmd, error) {
		return nil, errors.New("bad value")
	})

	m, _ := a.Update(press(tea.KeyEnter))
	a = m.(*App)
	if a.form == nil {
		t.Fatal("form closed despite validation error")
	}
	if a.form.err != "bad value" {
		t.Fatalf("form error = %q", a.form.err)
	}
	if !strings.Contains(a.View().Content, "bad value") {
		t.Fatal("view should render the form error")
	}

	m, _ = a.Update(press(tea.KeyEscape))
	a = m.(*App)
	if a.form != nil {
		t.Fatal("esc should close the form")
	}
}

func TestDashboardPanelsAndIcons(t *testing.T) {
	a := newTestApp(t)
	// Uniform spacing plus the fuller device card needs a little more room, so
	// use a terminal tall enough to show the device card and the hint box.
	a.height = 52
	view := a.View().Content
	for _, want := range []string{
		i18n.Chinese.T("panel_device"),
		i18n.Chinese.T("panel_hints"),
	} {
		if !strings.Contains(view, want) {
			t.Fatalf("view missing panel %q:\n%s", want, view)
		}
	}
	if strings.Contains(view, "[1]") {
		t.Fatalf("menu should use icons instead of bracketed numbers:\n%s", view)
	}

	// The node card lives inside node management instead of the main menu.
	a.push(buildNode())
	nodeView := a.View().Content
	if !strings.Contains(nodeView, i18n.Chinese.T("panel_node")) {
		t.Fatalf("node menu missing the node card:\n%s", nodeView)
	}
	if strings.Contains(nodeView, i18n.Chinese.T("panel_device")) {
		t.Fatalf("node menu should not show the device card:\n%s", nodeView)
	}
}

func TestDashboardShowsLogoAndMenuDescriptions(t *testing.T) {
	a := New("test", i18n.Chinese)
	a.width, a.height = 100, 46
	a.sized = true
	a.status = sysinfo.Collect("test")
	a.ready = true

	view := a.dashboard()
	if !strings.Contains(view, "██████") {
		t.Fatalf("tall dashboard should show the block-letter wordmark:\n%s", view)
	}
	if !strings.Contains(view, i18n.Chinese.T("menu_kernel")) {
		t.Fatalf("root menu should describe each entry:\n%s", view)
	}
	if !strings.Contains(view, i18n.Chinese.T("panel_overview")) {
		t.Fatalf("dashboard should show the overview section:\n%s", view)
	}
}

func TestDashboardFitsNarrowWidths(t *testing.T) {
	// Long English labels used to spill past the right border on small
	// terminals because the two-column and menu rows never clamped the label.
	for _, lang := range []i18n.Lang{i18n.Chinese, i18n.English} {
		for _, w := range []int{24, 32, 40, 60, 80} {
			a := New("test", lang)
			a.width, a.height = w, 40
			a.sized = true
			a.status = sysinfo.Collect("test")
			a.ready = true
			for _, line := range strings.Split(a.dashboard(), "\n") {
				if got := lipgloss.Width(line); got > w {
					t.Fatalf("lang %s width %d: line is %d cells: %q", lang, w, got, line)
				}
			}
		}
	}
}

func TestMouseWheelOnlyOnTaskScreen(t *testing.T) {
	a := newTestApp(t)
	if got := a.View().MouseMode; got != tea.MouseModeNone {
		t.Fatalf("dashboard should not capture the mouse, got %v", got)
	}
	p := newProgress("qr", func(context.Context, func(string)) error { return nil })
	p.resize(a.width, a.height)
	a.task = &p
	if got := a.View().MouseMode; got != tea.MouseModeCellMotion {
		t.Fatalf("task screen should enable mouse wheel, got %v", got)
	}
	// Releasing the mouse restores click-drag selection on the task screen.
	p.mouse = false
	if got := a.View().MouseMode; got != tea.MouseModeNone {
		t.Fatalf("released task mouse should not capture, got %v", got)
	}
}

func TestPublishSubscriptionNeedsHost(t *testing.T) {
	var logged []string
	err := publishSubscription(context.Background(), state.Config{},
		func(s string) { logged = append(logged, s) }, i18n.Chinese)
	if err != nil {
		t.Fatalf("publishSubscription returned %v", err)
	}
	if len(logged) == 0 || !strings.Contains(logged[0], i18n.Chinese.T("sub_need_domain")) {
		t.Fatalf("expected a need-domain hint, got %v", logged)
	}
}

func TestValidHopRange(t *testing.T) {
	cases := map[string]bool{
		"2080:3000": true,
		"1:2":       true,
		"3000:2080": false,
		"0:100":     false,
		"100:70000": false,
		"abc":       false,
		"":          false,
	}
	for in, want := range cases {
		if got := validHopRange(in); got != want {
			t.Errorf("validHopRange(%q) = %v, want %v", in, got, want)
		}
	}
}

func TestMenuCursorKeepsUniformWidth(t *testing.T) {
	// The selection bar is padded to the longest entry so it does not grow and
	// shrink as the cursor moves through rows with different length descriptions.
	a := New("test", i18n.Chinese)
	a.width, a.height = 100, 34
	a.sized = true
	a.status = sysinfo.Collect("test")
	a.ready = true

	inner := a.width - 4
	descCol := a.menuDescColumn(inner, a.menuLabelColumn())
	cursorWidth := a.menuCursorWidth(inner, descCol)

	longest := 0
	for _, n := range a.current().nodes {
		if w := a.menuRowWidth(n, inner, descCol); w > longest {
			longest = w
		}
	}
	if cursorWidth != longest {
		t.Fatalf("cursor width = %d, want longest row %d", cursorWidth, longest)
	}
	for i, n := range a.current().nodes {
		bar := a.menuRow(true, n, inner, descCol, cursorWidth)
		if got := lipgloss.Width(bar); got != cursorWidth {
			t.Fatalf("row %d bar width = %d, want %d", i, got, cursorWidth)
		}
	}
}

func TestPaletteFollowsTerminalBackground(t *testing.T) {
	a := New("test", i18n.Chinese)
	if !a.themeAuto {
		t.Fatal("the built-in theme should auto-detect the terminal background")
	}
	m, _ := a.Update(tea.BackgroundColorMsg{Color: color.White})
	a = m.(*App)
	if a.palette.Primary != theme.Light().Primary {
		t.Fatal("a light terminal background should select the light palette")
	}
	m, _ = a.Update(tea.BackgroundColorMsg{Color: color.Black})
	a = m.(*App)
	if a.palette.Primary != theme.Dark().Primary {
		t.Fatal("a dark terminal background should select the dark palette")
	}
}

func TestThemeEnvOverrideWins(t *testing.T) {
	t.Setenv("EASYSB_THEME", "light")
	a := New("test", i18n.Chinese)
	if a.themeAuto {
		t.Fatal("a forced theme should disable background auto-detection")
	}
	if a.palette.Primary != theme.Light().Primary {
		t.Fatal("EASYSB_THEME=light should start on the light palette")
	}
	m, _ := a.Update(tea.BackgroundColorMsg{Color: color.Black})
	a = m.(*App)
	if a.palette.Primary != theme.Light().Primary {
		t.Fatal("a forced theme must ignore the detected background")
	}
}
