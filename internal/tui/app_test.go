package tui

import (
	"context"
	"errors"
	"image/color"
	"strings"
	"testing"
	"time"

	tea "charm.land/bubbletea/v2"
	"charm.land/lipgloss/v2"

	"github.com/MinimaxFlora/EasySB/internal/i18n"
	"github.com/MinimaxFlora/EasySB/internal/state"
	"github.com/MinimaxFlora/EasySB/internal/sysinfo"
	"github.com/MinimaxFlora/EasySB/internal/theme"
	"github.com/MinimaxFlora/EasySB/internal/user"
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

	// ports is the second row of the params menu, right below the hop range.
	for i := 0; i < 1; i++ {
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
	if got := len(a.current().nodes); got != 8 {
		t.Fatalf("root should have 8 entries, got %d", got)
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
	if got := a.selected().id; got != "users" {
		t.Fatalf("digit 5 should select accounts, got %s", got)
	}
	m, _ = a.Update(press('6'))
	a = m.(*App)
	if got := a.selected().id; got != "service" {
		t.Fatalf("digit 6 should select service, got %s", got)
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
	// Eight root entries need two more rows than the seven the menu had before
	// accounts were added, and the banner is the first block dropped when the
	// terminal is shorter than that.
	a.width, a.height = 100, 48
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

func TestNoScreenCapturesTheMouse(t *testing.T) {
	a := newTestApp(t)
	if got := a.View().MouseMode; got != tea.MouseModeNone {
		t.Fatalf("dashboard should not capture the mouse, got %v", got)
	}
	p := newProgress("qr", func(context.Context, func(string)) error { return nil })
	p.resize(a.width, a.height)
	a.task = &p
	if got := a.View().MouseMode; got != tea.MouseModeNone {
		t.Fatalf("task screen should not capture the mouse, got %v", got)
	}
}

func TestUpperQQuitsFromSubscreens(t *testing.T) {
	a := newTestApp(t)
	a.links = newLinksModel("t", sampleLinks())
	if _, cmd := a.Update(press('Q')); cmd == nil {
		t.Fatal("upper-case Q should quit from the link panel")
	}

	a.links = nil
	p := newProgress("t", func(context.Context, func(string)) error { return nil })
	a.task = &p
	if _, cmd := a.Update(press('Q')); cmd == nil {
		t.Fatal("upper-case Q should quit from the task panel")
	}

	// Lower-case q on a subpage still steps back instead of quitting.
	a.task = nil
	a.links = newLinksModel("t", sampleLinks())
	m, cmd := a.Update(press('q'))
	if cmd != nil {
		t.Fatal("lower-case q should not quit the link panel")
	}
	if m.(*App).links != nil {
		t.Fatal("lower-case q should close the link panel")
	}
}

func TestEveryScreenUsesOneFixedFrame(t *testing.T) {
	// The whole point of the layout: the dashboard and every subpage render at
	// exactly the same size, so moving between them never resizes the panel and
	// the hint box never moves.
	lines := func(s string) int { return strings.Count(s, "\n") + 1 }
	screens := func(a *App) map[string]string {
		out := map[string]string{"dashboard": a.dashboard()}
		a.links = newLinksModel("t", sampleLinks())
		out["links"] = a.View().Content
		a.links = nil
		p := newProgress("t", func(context.Context, func(string)) error { return nil })
		a.task = &p
		out["task"] = a.View().Content
		a.task = nil
		a.openForm("t", "p", "", "", nil)
		out["form"] = a.View().Content
		a.form = nil

		// The account screens carry the longest values in the panel: names,
		// quotas and subscription URLs.
		account := user.New("a-very-long-account-name-for-layout", state.Keys, time.Unix(0, 0))
		account.QuotaBytes = 1 << 40
		account.UsedBytes = 1 << 30
		account.ExpireAt = time.Unix(0, 0).Add(48 * time.Hour)
		a.accounts = []user.User{account}
		a.push(a.usersMenu())
		out["accounts"] = a.View().Content
		a.push(a.userListMenu())
		out["account-list"] = a.View().Content
		a.push(a.userMenu(account.Token))
		out["account-detail"] = a.View().Content
		a.push(a.userProtocolsMenu(account.Token))
		out["account-protocols"] = a.View().Content
		return out
	}
	for _, w := range []int{20, 32, 60, 100, 140} {
		for _, h := range []int{6, 8, 10, 12, 14, 20, 34, 60} {
			a := New("test", i18n.Chinese)
			a.width, a.height = w, h
			a.sized = true
			a.status = sysinfo.Collect("test")
			a.ready = true

			limit := panelWidth(w)
			for name, content := range screens(a) {
				if got := lines(content); got != h {
					t.Fatalf("%dx%d %s: drew %d lines", w, h, name, got)
				}
				for _, line := range strings.Split(content, "\n") {
					if got := lipgloss.Width(line); got > limit {
						t.Fatalf("%dx%d %s: line is %d cells (limit %d): %q", w, h, name, got, limit, line)
					}
				}
			}
		}
	}
}

func TestLogEndpointNeedsHost(t *testing.T) {
	var logged []string
	logEndpoint(state.Config{}, func(s string) { logged = append(logged, s) }, i18n.Chinese)
	if len(logged) == 0 || !strings.Contains(logged[0], i18n.Chinese.T("sub_need_domain")) {
		t.Fatalf("expected a need-domain hint, got %v", logged)
	}
}

func TestLogEndpointWarnsWithoutCertificate(t *testing.T) {
	cfg := state.Default()
	// A server IP is enough for a host, but it is not a domain with a
	// certificate, so the endpoint will speak plain HTTP.
	cfg.ServerIP = "203.0.113.10"
	var logged []string
	logEndpoint(cfg, func(s string) { logged = append(logged, s) }, i18n.Chinese)
	joined := strings.Join(logged, "\n")
	if !strings.Contains(joined, i18n.Chinese.T("sub_plaintext_warning")) {
		t.Fatalf("expected a plaintext warning, got %v", logged)
	}
	if !strings.Contains(joined, "http://203.0.113.10:8443/sub/") {
		t.Fatalf("endpoint URL should match the plain listener: %v", logged)
	}
}

func TestAccountScreensRenderAccount(t *testing.T) {
	a := New("test", i18n.Chinese)
	a.width, a.height = 100, 40
	a.sized = true
	a.status = sysinfo.Collect("test")
	a.ready = true

	account := user.New("alice", state.Keys, time.Now())
	account.QuotaBytes = 1 << 40
	account.UsedBytes = 1 << 30
	a.accounts = []user.User{account}

	a.push(a.userListMenu())
	view := a.View().Content
	if !strings.Contains(view, "alice") {
		t.Fatalf("account list should show the account name:\n%s", view)
	}
	if !strings.Contains(view, i18n.Chinese.T("user_status_active")) {
		t.Fatalf("account list should show the status:\n%s", view)
	}

	a.push(a.userMenu(account.Token))
	view = a.View().Content
	for _, want := range []string{
		"alice",
		i18n.Chinese.T("user_quota"),
		i18n.Chinese.T("user_protocols"),
		i18n.Chinese.T("user_sub"),
	} {
		if !strings.Contains(view, want) {
			t.Fatalf("account detail missing %q:\n%s", want, view)
		}
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
	// The selection bar spans the full inner width so it stays one size as the
	// cursor moves through rows with different length descriptions.
	a := New("test", i18n.Chinese)
	a.width, a.height = 100, 34
	a.sized = true
	a.status = sysinfo.Collect("test")
	a.ready = true

	inner := a.width - 4
	descCol := a.menuDescColumn(inner, a.menuLabelColumn())
	cursorWidth := a.menuCursorWidth(inner)
	if cursorWidth != inner {
		t.Fatalf("cursor width = %d, want inner %d", cursorWidth, inner)
	}
	for i, n := range a.current().nodes {
		bar := a.menuRow(true, n, inner, descCol, cursorWidth)
		if got := lipgloss.Width(bar); got != cursorWidth {
			t.Fatalf("row %d bar width = %d, want %d", i, got, cursorWidth)
		}
	}
}

func TestSubmenuShowsDescriptions(t *testing.T) {
	a := New("test", i18n.Chinese)
	a.width, a.height = 100, 46
	a.sized = true
	a.status = sysinfo.Collect("test")
	a.ready = true

	a.push(buildSubscribe())
	view := a.View().Content
	for _, key := range []string{"desc_sub_url", "desc_sub_qr", "desc_sub_links", "desc_sub_svc_install"} {
		if !strings.Contains(view, i18n.Chinese.T(key)) {
			t.Fatalf("subscription submenu missing description %q:\n%s", key, view)
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
