package tui

import (
	"context"
	"errors"
	"image/color"
	"path/filepath"
	"regexp"
	"strings"
	"testing"
	"time"

	tea "charm.land/bubbletea/v2"
	"charm.land/lipgloss/v2"

	"github.com/MinimaxFlora/EasySB/internal/bbr"
	"github.com/MinimaxFlora/EasySB/internal/core"
	"github.com/MinimaxFlora/EasySB/internal/i18n"
	"github.com/MinimaxFlora/EasySB/internal/prefs"
	"github.com/MinimaxFlora/EasySB/internal/state"
	"github.com/MinimaxFlora/EasySB/internal/sysinfo"
	"github.com/MinimaxFlora/EasySB/internal/theme"
	"github.com/MinimaxFlora/EasySB/internal/user"
)

func press(code rune) tea.KeyPressMsg {
	return tea.KeyPressMsg(tea.Key{Code: code})
}

// ansiSGR matches the colour sequences the panel wraps its text in, so a test can
// look for the text itself.
var ansiSGR = regexp.MustCompile("\x1b\\[[0-9;]*m")

func stripANSI(s string) string { return ansiSGR.ReplaceAllString(s, "") }

func typeRune(r rune) tea.KeyPressMsg {
	return tea.KeyPressMsg(tea.Key{Code: r, Text: string(r)})
}

func newTestApp(t *testing.T) *App {
	t.Helper()
	// The interface choices are written to disk, so they go to a temporary file
	// instead of the real panel directory.
	t.Setenv(prefs.PathEnv, filepath.Join(t.TempDir(), "easysb-ui.conf"))
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
	// The root entries are the panel's map: every screen has to be reachable from
	// here, and from the navigation grouping as well, or it is hidden behind a
	// scroll nobody knows about.
	want := []string{"kernel", "node", "domain", "subscribe", "users", "service", "system", "bbr", "script-update", "uninstall"}
	got := map[string]bool{}
	for _, n := range a.current().nodes {
		got[n.id] = true
	}
	for _, id := range want {
		if !got[id] {
			t.Errorf("root menu is missing %q", id)
		}
	}
	if len(a.current().nodes) != len(want) {
		t.Errorf("root has %d entries, expected %d", len(a.current().nodes), len(want))
	}
	placed := map[string]bool{}
	for _, g := range a.style().Met.Groups {
		for _, id := range g.IDs {
			placed[id] = true
		}
	}
	for _, n := range a.current().nodes {
		if !placed[n.id] {
			t.Errorf("entry %q is in no navigation group of the default skin", n.id)
		}
	}
	// Every skin carries its own grouping, and an entry missing from one of them
	// disappears from that skin's navigation column without any other symptom.
	for _, skin := range theme.Skins() {
		grouped := map[string]bool{}
		for _, g := range skin.Met.Groups {
			for _, id := range g.IDs {
				grouped[id] = true
			}
		}
		for _, n := range a.current().nodes {
			if !grouped[n.id] {
				t.Errorf("skin %q does not group the root entry %q", skin.ID, n.id)
			}
		}
	}
	if !got["uninstall"] {
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
	want := []string{"kernel-switch", "kernel-update"}
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
	for _, label := range []string{"切换内核", "更新内核", i18n.Chinese.T("nav_back")} {
		if !strings.Contains(view, label) {
			t.Fatalf("kernel menu view missing %q: %s", label, view)
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

// Switching the core is one list of the four channel/source combinations, so taking the
// official core and going back to the author's build are the same kind of move.
func TestKernelSwitchEntries(t *testing.T) {
	a := newTestApp(t)
	a.push(buildKernelSwitch())
	want := []struct{ id, label string }{
		{"kernel-apply-stable-author", "正式版 · 作者源"},
		{"kernel-apply-alpha-author", "测试版 · 作者源"},
		{"kernel-apply-stable-official", "正式版 · 官方源"},
		{"kernel-apply-alpha-official", "测试版 · 官方源"},
	}
	if got := len(a.current().nodes); got != len(want) {
		t.Fatalf("switch menu has %d entries, want %d", got, len(want))
	}
	view := a.View().Content
	for i, entry := range want {
		if got := a.current().nodes[i].id; got != entry.id {
			t.Fatalf("switch entry %d = %s, want %s", i, got, entry.id)
		}
		if got := a.current().nodes[i].label(i18n.Chinese); got != entry.label {
			t.Fatalf("switch entry %d label = %q, want %q", i, got, entry.label)
		}
		if !strings.Contains(view, entry.label) {
			t.Fatalf("switch menu view missing %q: %s", entry.label, view)
		}
	}
	if !a.hasNavRow() {
		t.Fatalf("switch menu should show a navigation row")
	}
}

// The combination that is installed is marked, and the mark comes from the recorded state:
// without a record nothing is marked, because the core page's 看板 answers from the binary.
func TestKernelCurrentKey(t *testing.T) {
	cases := []struct {
		name string
		cfg  state.Config
		want string
	}{
		{"author stable", state.Config{CoreChannel: "stable", CoreSource: core.SourceBuild}, "stable:build"},
		{"official alpha", state.Config{CoreChannel: "alpha", CoreSource: core.SourceUpstream}, "alpha:upstream"},
		{"channel missing", state.Config{CoreSource: core.SourceBuild}, "stable:build"},
		{"no record", state.Config{CoreChannel: "stable"}, ""},
		{"nothing at all", state.Config{}, ""},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			if got := kernelCurrentKey(tc.cfg); got != tc.want {
				t.Fatalf("kernelCurrentKey(%+v) = %q, want %q", tc.cfg, got, tc.want)
			}
		})
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
	a.height = 52
	view := a.View().Content
	if !strings.Contains(view, i18n.Chinese.T("panel_hints")) {
		t.Fatalf("view missing the hint box:\n%s", view)
	}
	if !strings.Contains(view, i18n.Chinese.T("menu_main")) {
		t.Fatalf("view missing the main menu card:\n%s", view)
	}
	// The host card belongs to the system screen now: the main menu keeps its
	// width for the entries and their two columns.
	for _, gone := range []string{i18n.Chinese.T("panel_device"), i18n.Chinese.T("panel_accounts")} {
		if strings.Contains(view, gone) {
			t.Fatalf("main menu should not show %q:\n%s", gone, view)
		}
	}
	if strings.Contains(view, "[1]") {
		t.Fatalf("menu should use icons instead of bracketed numbers:\n%s", view)
	}

	a.openSystem()
	if got := a.View().Content; !strings.Contains(got, i18n.Chinese.T("panel_device")) {
		t.Fatalf("system screen should show the host card:\n%s", got)
	}
	a.closeSystem()

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
	a.width, a.height = 100, 48
	a.sized = true
	a.status = sysinfo.Collect("test")
	a.ready = true

	view := stripANSI(a.dashboard())
	if !strings.Contains(view, "██████") {
		t.Fatalf("tall dashboard should show the block-letter wordmark:\n%s", view)
	}
	// The wordmark and the vitals share one card, in that order, above the menu.
	lines := strings.Split(view, "\n")
	at := func(s string) int {
		for i, line := range lines {
			if strings.Contains(line, s) {
				return i
			}
		}
		return -1
	}
	mark, vitals, menu := at("██████"), at(i18n.Chinese.T("status_autostart")), at(i18n.Chinese.T("menu_main"))
	if mark < 0 || vitals < 0 || menu < 0 {
		t.Fatalf("wordmark %d, vitals %d, menu %d — one of them is missing:\n%s", mark, vitals, menu, view)
	}
	if !(mark < vitals && vitals < menu) {
		t.Fatalf("expected wordmark(%d) then vitals(%d) then menu(%d):\n%s", mark, vitals, menu, view)
	}
	// The vitals are inside the wordmark's card: a rule is the only thing
	// separating the two halves, and the card's own border is not one.
	rule := -1
	for i := mark; i < vitals; i++ {
		inner := strings.Trim(strings.TrimSpace(strings.Trim(lines[i], "│")), "─═")
		if inner == "" && strings.ContainsAny(lines[i], "─═") {
			rule = i
			break
		}
	}
	if rule < 0 {
		t.Fatalf("no rule between the wordmark and the vitals:\n%s", view)
	}
	// The entries live in their own box under the 看板: that is the frame every
	// page of the panel shares — 看板 on top, entries below — and it is what the
	// lines between the two halves have to prove.
	split := -1
	for i := vitals; i < menu; i++ {
		if strings.ContainsAny(lines[i], "╭╰") {
			split = i
			break
		}
	}
	if split < 0 {
		t.Fatalf("the menu is not in a box of its own after the 看板:\n%s", view)
	}
	// The hints follow the menu instead of being pinned to the bottom, which is
	// what leaves the gap the user asked to close: the menu card's bottom border
	// and the explanation line are all that sit between them.
	hint := at(i18n.Chinese.T("panel_hints"))
	last := at("[ 10 ]")
	if hint < 0 || last < 0 {
		t.Fatalf("hints %d, last entry %d:\n%s", hint, last, view)
	}
	if hint-last > 4 {
		t.Fatalf("hints at line %d, last entry at %d — they are not right under the menu:\n%s", hint, last, view)
	}
	if hint+3 >= len(lines)-1 {
		t.Fatalf("hints at line %d of %d lines — they are pinned to the bottom:\n%s", hint, len(lines), view)
	}
}

// TestEverySectionHasItsOwnPanel guards the frame the panel is built around: every
// second-level page shows a 看板 of its own in the top box and its entries in the
// bottom one, so moving between pages swaps those two contents and nothing else.
func TestEverySectionHasItsOwnPanel(t *testing.T) {
	ids := []string{"kernel", "node", "domain", "subscribe", "users", "service", "bbr", "script-update", "uninstall"}
	seen := make(map[string]string, len(ids))
	for _, id := range ids {
		a := newTestApp(t)
		a.width, a.height = 100, 40
		a.section = id
		title, rows := a.sectionPanel(a.width)
		if strings.TrimSpace(title) == "" {
			t.Errorf("section %q has no 看板 title", id)
		}
		if len(rows) == 0 {
			t.Errorf("section %q has no 看板 rows", id)
		}
		if first, ok := seen[title]; ok {
			t.Errorf("sections %q and %q share the 看板 title %q", first, id, title)
		}
		seen[title] = id

		// The rendered page is two boxes: the 看板 and, under it, the entries.
		view := stripANSI(a.dashboard())
		boxes := strings.Count(view, "╭")
		if boxes < 2 {
			t.Errorf("section %q renders %d boxes, want the 看板 and the entries:\n%s", id, boxes, view)
		}
		if !strings.Contains(view, title) {
			t.Errorf("section %q does not render its 看板 title %q:\n%s", id, title, view)
		}
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

func TestFitsNarrowWidthsEveryScreen(t *testing.T) {
	// The main menu gained a second column and a section of its own, so every
	// screen is checked at the widths where columns start to collapse.
	for _, lang := range []i18n.Lang{i18n.Chinese, i18n.English} {
		for _, screen := range []string{"", "bbr", "bbr-qdisc", "system"} {
			for _, w := range []int{40, 60, 76, 100} {
				a := New("test", lang)
				a.sized = true
				a.status = sysinfo.Collect("test")
				a.ready = true
				for _, line := range strings.Split(a.SnapshotScreen(screen, w, 40), "\n") {
					if got := lipgloss.Width(line); got > w {
						t.Fatalf("lang %s screen %q width %d: line is %d cells: %q", lang, screen, w, got, line)
					}
				}
			}
		}
	}
}

func TestBBRMenuShape(t *testing.T) {
	a := newTestApp(t)
	if n := len(a.current().nodes); n != 10 {
		t.Fatalf("the main menu has %d entries, want 10", n)
	}
	// The tenth entry opens a section of its own.
	var bbrNode *node
	for _, n := range a.current().nodes {
		if n.id == "bbr" {
			bbrNode = n
		}
	}
	if bbrNode == nil || bbrNode.sub == nil {
		t.Fatal("the main menu has no BBR section")
	}
	// Two columns of five fill the card: the second column starts at the entries
	// after the fifth, and the last entry stays reachable on the same screen.
	view := a.SnapshotScreen("", 100, 40)
	for _, want := range []string{i18n.Chinese.T("kernel_title"), i18n.Chinese.T("svc_title"), i18n.Chinese.T("menu_uninstall")} {
		if !strings.Contains(view, want) {
			t.Fatalf("main menu missing %q:\n%s", want, view)
		}
	}

	qdisc := a.SnapshotScreen("bbr-qdisc", 100, 40)
	for _, q := range []string{"fq", "fq_codel", "fq_pie", "cake"} {
		if !strings.Contains(qdisc, q) {
			t.Fatalf("queue discipline menu missing %q:\n%s", q, qdisc)
		}
	}
}

func TestMainMenuArrowKeysFollowTheColumns(t *testing.T) {
	a := newTestApp(t)
	if a.menuColumns() != 2 {
		t.Fatalf("the main menu should be drawn in two columns at %d columns wide", a.width)
	}
	half := len(a.current().nodes) / 2

	// Down walks the left column and stays in it: the entries below the fold are
	// the ones in the other column, so a step across would look like a jump.
	for i := 0; i < half-1; i++ {
		m, _ := a.Update(press(tea.KeyDown))
		a = m.(*App)
	}
	if a.index != half-1 {
		t.Fatalf("down from the top of the left column landed on %d, want %d", a.index, half-1)
	}
	// One more down wraps inside the column instead of crossing to the other one.
	m, _ := a.Update(press(tea.KeyDown))
	a = m.(*App)
	if a.index != 0 {
		t.Fatalf("down at the bottom of the left column landed on %d, want 0", a.index)
	}
	m, _ = a.Update(press(tea.KeyUp))
	a = m.(*App)
	if a.index != half-1 {
		t.Fatalf("up at the top of the left column landed on %d, want %d", a.index, half-1)
	}

	// Right moves to the same row of the right column, left comes back.
	m, _ = a.Update(press(tea.KeyRight))
	a = m.(*App)
	if want := 2*half - 1; a.index != want {
		t.Fatalf("right from the last row landed on %d, want %d", a.index, want)
	}
	m, _ = a.Update(press(tea.KeyLeft))
	a = m.(*App)
	if a.index != half-1 {
		t.Fatalf("left landed on %d, want %d", a.index, half-1)
	}

	// Enter still opens the highlighted entry from either column.
	m, _ = a.Update(press(tea.KeyEnter))
	a = m.(*App)
	if a.current().id == "root" {
		t.Fatal("enter should have left the main menu")
	}
}

func TestMainMenuNarrowFallsBackToSingleColumn(t *testing.T) {
	a := newTestApp(t)
	// Two columns need about 37 columns of card before each of them is too narrow
	// to hold a label.
	m, _ := a.Update(tea.WindowSizeMsg{Width: 36, Height: 34})
	a = m.(*App)
	if a.menuColumns() != 1 {
		t.Fatal("a 36-column terminal cannot hold two columns")
	}
	m, _ = a.Update(press(tea.KeyDown))
	a = m.(*App)
	if a.index != 1 {
		t.Fatalf("down moved to %d, want 1", a.index)
	}
	// With one column the arrows keep their old meaning: right opens the entry.
	m, _ = a.Update(press(tea.KeyRight))
	a = m.(*App)
	if a.current().id == "root" {
		t.Fatal("right should still enter a screen when there is only one column")
	}
}

func TestBBRVersionListShowsPublishedKernels(t *testing.T) {
	a := newTestApp(t)
	a.push(buildBBR())
	a.section = "bbr"
	a.bbrVersionsLoading = true
	a.push(a.bbrVersionsMenu())

	// While the fetch is in flight the screen says so instead of looking empty.
	loading := a.Snapshot(100, 34)
	if !strings.Contains(loading, i18n.Chinese.T("bbr_versions_loading")) {
		t.Fatalf("the loading row is missing:\n%s", loading)
	}

	// A finished fetch lists every published kernel and marks the one this machine
	// already runs.
	a.applyBBRVersions(bbrVersionsMsg{
		list: []bbr.Release{
			{Tag: "x86_64-9.9.9", Version: "9.9.9", Profile: bbr.Standard},
			{Tag: "x86_64-9.9.9-max", Version: "9.9.9", Profile: bbr.Max},
			{Tag: "x86_64-9.9.8", Version: "9.9.8", Profile: bbr.Standard},
		},
		status: bbr.Status{
			Running: "9.9.8-minimaxflora-bbrv3",
			Kernels: []string{"linux-image-9.9.8-minimaxflora-bbrv3"},
		},
	})
	view := a.Snapshot(100, 34)
	for _, want := range []string{"9.9.9", "9.9.8", i18n.Chinese.T("bbr_versions_running"), i18n.Chinese.T("bbr_versions_latest")} {
		if !strings.Contains(view, want) {
			t.Fatalf("the version list is missing %q:\n%s", want, view)
		}
	}
	nodes := a.current().nodes
	if len(nodes) != 3 {
		t.Fatalf("the list has %d rows, want one per published kernel", len(nodes))
	}
	if nodes[0].action == nil {
		t.Fatal("a version row must install that version when entered")
	}

	// A failed fetch explains itself rather than rendering an empty list.
	a.applyBBRVersions(bbrVersionsMsg{err: errors.New("network unreachable")})
	view = a.Snapshot(100, 34)
	if !strings.Contains(view, i18n.Chinese.T("bbr_versions_failed")) {
		t.Fatalf("the failure row is missing:\n%s", view)
	}
}

func TestNoScreenCapturesTheMouse(t *testing.T) {
	a := newTestApp(t)
	if got := a.View().MouseMode; got != tea.MouseModeNone {
		t.Fatalf("dashboard should not capture the mouse, got %v", got)
	}
	p := newProgress("qr", func(context.Context, *taskReporter) error { return nil })
	p.resize(a.width, a.height)
	a.task = p
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
	p := newProgress("t", func(context.Context, *taskReporter) error { return nil })
	a.task = p
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

func TestEveryScreenUsesOneFixedFrame(t *testing.T) { // The whole point of the layout: the dashboard and every subpage render at
	// exactly the same size, so moving between them never resizes the panel and
	// the hint box never moves.
	lines := func(s string) int { return strings.Count(s, "\n") + 1 }
	screens := func(a *App) map[string]string {
		out := map[string]string{"dashboard": a.dashboard()}
		a.links = newLinksModel("t", sampleLinks())
		out["links"] = a.View().Content
		a.links = nil
		p := newProgress("t", func(context.Context, *taskReporter) error { return nil })
		a.task = p
		out["task"] = a.View().Content
		// A download in flight shares the card with the log, so the bar has to fit
		// every size the frame is promised at.
		p.setDownload("linux-image-7.2.6-minimaxflora-bbrv3-max_7.2.6-1_amd64.deb", 118<<20, 240<<20)
		out["task-downloading"] = a.View().Content
		a.task = nil
		a.openForm("t", "p", "", "", nil)
		out["form"] = a.View().Content
		a.form = nil
		a.openSystem()
		out["system"] = a.View().Content
		a.system = nil

		// Every page under the main menu, and the subpage each one hangs further
		// down: the two boxes have to hold whatever a section puts in them.
		for _, n := range buildRoot().nodes {
			if n.sub == nil {
				continue
			}
			a.stack = a.stack[:1]
			a.section = n.id
			a.push(n.sub)
			out["page:"+n.id] = a.View().Content
			for _, sub := range n.sub.nodes {
				if sub.sub == nil {
					continue
				}
				a.push(sub.sub)
				out["page:"+n.id+"/"+sub.id] = a.View().Content
				break
			}
		}
		a.stack = a.stack[:1]
		a.section = ""

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
	// Every skin has to hold the same frame: a skin that pads, tints or frames
	// differently must not change the size of a single screen.
	skins := theme.Skins()
	status := sysinfo.Collect("test")

	for _, skin := range skins {
		for _, dark := range []bool{true, false} {
			for _, w := range []int{20, 32, 60, 100, 140} {
				for _, h := range []int{6, 8, 10, 12, 14, 20, 34, 60} {
					a := New("test", i18n.Chinese)
					a.setSkin(skin, dark)
					a.width, a.height = w, h
					a.sized = true
					a.status = status
					a.ready = true

					limit := panelWidth(w)
					for name, content := range screens(a) {
						if got := lines(content); got != h {
							t.Fatalf("%s dark=%v %dx%d %s: drew %d lines", skin.ID, dark, w, h, name, got)
						}
						for _, line := range strings.Split(content, "\n") {
							if got := lipgloss.Width(line); got > limit {
								t.Fatalf("%s dark=%v %dx%d %s: line is %d cells (limit %d): %q", skin.ID, dark, w, h, name, got, limit, line)
							}
						}
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

// TestBBRPanelShowsPendingReboot keeps the one thing an operator has to do after
// installing a kernel on the page: the new kernel only runs after a reboot, and a
// panel that reports it installed without saying so invites a bug report.
func TestBBRPanelShowsPendingReboot(t *testing.T) {
	newApp := func() *App {
		a := New("test", i18n.Chinese)
		a.width, a.height = 100, 34
		a.sized = true
		a.status = sysinfo.Collect("test")
		a.ready = true
		a.section = "bbr"
		a.push(buildBBR())
		return a
	}

	pending := newApp()
	pending.bbrStatus = bbr.Status{
		Running:    "6.12.48+deb13-amd64",
		Congestion: "cubic",
		Kernels:    []string{"linux-image-7.2.7-minimaxflora-bbrv3"},
	}
	if view := pending.View().Content; !strings.Contains(view, i18n.Chinese.T("bbr_reboot_pending")) {
		t.Fatalf("a kernel waiting for a reboot should say so:\n%s", view)
	}

	running := newApp()
	running.bbrStatus = bbr.Status{
		Running:    "7.2.7-minimaxflora-bbrv3",
		Congestion: "bbr",
		Kernels:    []string{"linux-image-7.2.7-minimaxflora-bbrv3"},
	}
	if view := running.View().Content; strings.Contains(view, i18n.Chinese.T("bbr_reboot_pending")) {
		t.Fatalf("a kernel that is already running should not ask for a reboot:\n%s", view)
	}
}

// TestSectionPanelRefreshesAfterTask keeps the 看板 of a section that reads the
// machine in step with the task that just changed it.
func TestSectionPanelRefreshesAfterTask(t *testing.T) {
	a := New("test", i18n.Chinese)
	a.section = "bbr"
	if a.sectionRefresh() == nil {
		t.Fatal("a task that finished in the BBR section should re-read its panel")
	}
	a.section = "domain"
	if a.sectionRefresh() != nil {
		t.Fatal("a section whose panel only reads the status strip needs no re-read")
	}
}

// TestRootEntriesOpenPages covers the frame the operator is left in after a root
// entry: every entry of the main menu opens a page of its own, so the top box is that
// page's 看板 and Esc walks back to the main menu. An entry that used to run its
// action in place showed this section's 看板 above the main menu and made Esc quit.
func TestRootEntriesOpenPages(t *testing.T) {
	// The index of a root entry, looked up from the menu itself so the test does not
	// depend on anything besides the entries the panel builds.
	rootIndex := func(id string) int {
		for i, n := range buildRoot().nodes {
			if n.id == id {
				return i
			}
		}
		return -1
	}
	for _, id := range []string{"script-update", "uninstall"} {
		a := New("test", i18n.Chinese)
		a.width, a.height = 100, 33
		a.sized = true
		a.status = sysinfo.Collect("test")
		a.ready = true
		a.index = rootIndex(id)

		m, _ := a.Update(press(tea.KeyEnter))
		a = m.(*App)
		if len(a.stack) != 2 {
			t.Fatalf("%s: Enter should open a page, stack is %d deep", id, len(a.stack))
		}
		if a.sectionID() != id {
			t.Fatalf("%s: the page should carry its own section, got %q", id, a.sectionID())
		}
		// The page is the same two boxes as every other: its 看板 on top, its own
		// entries below, titled with the page.
		view := a.View().Content
		title, rows := a.sectionPanel(a.frameWidth())
		if title == "" || len(rows) == 0 {
			t.Fatalf("%s: the page has no 看板", id)
		}
		if !strings.Contains(stripANSI(view), title) {
			t.Fatalf("%s: the page should draw the %q 看板:\n%s", id, title, view)
		}
		if got := strings.Count(stripANSI(view), i18n.Chinese.T("menu_main")); got != 0 {
			t.Fatalf("%s: the main menu should not be on screen inside a page", id)
		}
		if !strings.Contains(stripANSI(view), i18n.Chinese.T("nav_back")) {
			t.Fatalf("%s: the page should offer the way back:\n%s", id, view)
		}

		// Esc leaves the page instead of quitting the panel.
		m, cmd := a.Update(press(tea.KeyEscape))
		a = m.(*App)
		if cmd != nil {
			t.Fatalf("%s: Esc on a page should step back, not quit", id)
		}
		if len(a.stack) != 1 || a.sectionID() != "" {
			t.Fatalf("%s: Esc should return to the main menu, stack=%d section=%q", id, len(a.stack), a.sectionID())
		}
	}
}

// TestRootRunInPlaceLeavesNoSection pins the invariant behind that frame: an entry
// that runs an action without opening a page must not claim a section.
func TestRootRunInPlaceLeavesNoSection(t *testing.T) {
	a := New("test", i18n.Chinese)
	a.width, a.height = 100, 33
	a.sized = true
	a.status = sysinfo.Collect("test")
	a.ready = true
	for i, n := range buildRoot().nodes {
		if n.sub != nil || n.action == nil {
			continue
		}
		a.section = ""
		a.stack = a.stack[:1]
		a.index = i
		if n.id == "system" {
			continue // the system screen is a page of its own and says so
		}
		m, _ := a.Update(press(tea.KeyEnter))
		a = m.(*App)
		if a.section != "" {
			t.Fatalf("%s runs in place and must not set a section, got %q", n.id, a.section)
		}
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

	a.push(a.usersMenu())
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
		bar := a.menuRow(true, i, n, inner, descCol, cursorWidth)
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

// The core page has to say whether the installed core came from this repository's builds
// or from the official releases, and whether it can count traffic: the source decides
// whether per-account accounting works at all.
func TestCoreSourceLabel(t *testing.T) {
	cases := []struct {
		name    string
		source  string
		stats   bool
		want    string
		wantRow string
	}{
		{"recorded author source", core.SourceBuild, true, "作者源", "作者源 · 带流量统计"},
		{"recorded author source, binary without counters", core.SourceBuild, false, "作者源", "作者源 · 无流量统计"},
		{"recorded official source", core.SourceUpstream, false, "官方源", "官方源 · 无流量统计"},
		{"no record, counters present", "", true, "作者源", "作者源 · 带流量统计"},
		{"no record, no counters", "", false, "官方源", "官方源 · 无流量统计"},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			a := newTestApp(t)
			a.status.CoreSource = tc.source
			a.status.StatsCapable = tc.stats
			if got := a.coreSourceLabel(); got != tc.want {
				t.Fatalf("coreSourceLabel = %q, want %q", got, tc.want)
			}
			if got := a.coreSourceText(); got != tc.wantRow {
				t.Fatalf("coreSourceText = %q, want %q", got, tc.wantRow)
			}
			// The version line names the source too, so the answer is on every page.
			summary, _ := a.coreSummary()
			if !strings.Contains(summary, tc.want) {
				t.Fatalf("coreSummary = %q, want it to name %q", summary, tc.want)
			}
		})
	}
}
