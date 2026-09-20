package tui

import (
	"context"
	"fmt"
	"strings"
	"time"

	"charm.land/bubbles/v2/spinner"
	tea "charm.land/bubbletea/v2"
	"charm.land/lipgloss/v2"

	"github.com/MinimaxFlora/EasySB/internal/i18n"
	"github.com/MinimaxFlora/EasySB/internal/icons"
	"github.com/MinimaxFlora/EasySB/internal/netutil"
	"github.com/MinimaxFlora/EasySB/internal/sysinfo"
	"github.com/MinimaxFlora/EasySB/internal/theme"
)

type statusMsg sysinfo.Status

type publicIPMsg string

type App struct {
	scriptVersion string
	lang          i18n.Lang
	iconSet       icons.Set
	palette       theme.Palette
	stack         []*menu
	index         int
	width         int
	height        int
	status        sysinfo.Status
	ready         bool
	sized         bool
	quote         string
	toast         string
	toastErr      bool
	task          *progressModel
	form          *formModel
}

func New(scriptVersion string, lang i18n.Lang) *App {
	return &App{
		scriptVersion: scriptVersion,
		lang:          lang,
		iconSet:       icons.Detect(),
		palette:       theme.Dark(),
		stack:         []*menu{buildRoot()},
		quote:         lang.Hitokoto(),
	}
}

func (a *App) Init() tea.Cmd {
	return tea.Batch(collectStatus(a.scriptVersion), fetchPublicIP())
}

func (a *App) Snapshot(width, height int) string {
	a.width, a.height = width, height
	a.sized = true
	a.status = sysinfo.Collect(a.scriptVersion)
	a.ready = true
	return a.dashboard()
}

func collectStatus(version string) tea.Cmd {
	return func() tea.Msg {
		return statusMsg(sysinfo.Collect(version))
	}
}

// fetchPublicIP probes the public IP in the background so the dashboard never
// blocks on the network. The result only fills a gap left by the state file.
func fetchPublicIP() tea.Cmd {
	return func() tea.Msg {
		ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
		defer cancel()
		ip, err := netutil.PublicIP(ctx)
		if err != nil {
			return publicIPMsg("")
		}
		return publicIPMsg(ip)
	}
}

func quit() tea.Cmd {
	return func() tea.Msg { return tea.Quit() }
}

func (a *App) current() *menu { return a.stack[len(a.stack)-1] }

// inNodeManagement reports whether the current screen lives under the node
// management menu, where the node parameter card replaces the device card.
func (a *App) inNodeManagement() bool {
	for i := 1; i < len(a.stack); i++ {
		if a.stack[i].id == "node" {
			return true
		}
	}
	return false
}

func (a *App) push(m *menu) {
	a.stack = append(a.stack, m)
	a.index = 0
}

func (a *App) pop() {
	if len(a.stack) > 1 {
		a.stack = a.stack[:len(a.stack)-1]
		a.index = 0
	}
}

func (a *App) move(d int) {
	n := a.itemCount()
	if n == 0 {
		return
	}
	a.index = (a.index + d + n) % n
}

// itemCount is the number of selectable rows: menu nodes plus the trailing
// navigation row ("back") when the current menu is not the root.
func (a *App) itemCount() int {
	n := len(a.current().nodes)
	if n == 0 {
		return 1
	}
	if a.hasNavRow() {
		return n + 1
	}
	return n
}

// hasNavRow reports whether the current menu shows the trailing navigation
// row. The root menu has none: quit with Q/Esc.
func (a *App) hasNavRow() bool {
	return len(a.stack) > 1
}

// onNavRow reports whether the cursor sits on the trailing navigation row.
func (a *App) onNavRow() bool {
	return a.hasNavRow() && a.index >= len(a.current().nodes)
}

// navLabel is the label of the trailing navigation row.
func (a *App) navLabel() string {
	return a.lang.T("nav_back")
}

func (a *App) selected() *node {
	nodes := a.current().nodes
	if len(nodes) == 0 || a.onNavRow() {
		return nil
	}
	if a.index >= len(nodes) {
		a.index = len(nodes) - 1
	}
	return nodes[a.index]
}

func (a *App) setToast(msg string, warn bool) {
	a.toast = msg
	a.toastErr = warn
}

func (a *App) enter() tea.Cmd {
	if a.onNavRow() {
		if len(a.stack) > 1 {
			a.pop()
			return nil
		}
		return quit()
	}
	n := a.selected()
	if n == nil {
		return nil
	}
	if n.sub != nil {
		a.push(n.sub)
		return nil
	}
	if n.action != nil {
		return n.action(a)
	}
	return nil
}

func (a *App) startTask(title string, fn taskFunc) tea.Cmd {
	p := newProgress(title, fn)
	p.resize(a.width, a.height)
	a.task = &p
	return p.Init()
}

// openForm shows a single-value text prompt over the dashboard.
func (a *App) openForm(title, prompt, initial, hint string, submit formSubmit) {
	f := newForm(title, prompt, initial, hint, submit)
	f.resize(a.width)
	a.form = f
}

func (a *App) handleFormKey(msg tea.KeyPressMsg) (tea.Model, tea.Cmd) {
	f := a.form
	if f == nil {
		return a, nil
	}
	switch strings.ToLower(msg.String()) {
	case "ctrl+c":
		return a, quit()
	case "esc":
		a.form = nil
		return a, nil
	case "enter":
		var cmd tea.Cmd
		if f.submit != nil {
			var err error
			cmd, err = f.submit(a, f.input.Value())
			if err != nil {
				f.err = err.Error()
				return a, nil
			}
		}
		if a.form == f {
			a.form = nil
		}
		return a, tea.Batch(cmd, collectStatus(a.scriptVersion))
	default:
		return a, f.update(msg)
	}
}

func (a *App) Update(msg tea.Msg) (tea.Model, tea.Cmd) {
	switch msg := msg.(type) {
	case tea.WindowSizeMsg:
		a.width, a.height = msg.Width, msg.Height
		a.sized = true
		if a.task != nil {
			a.task.resize(msg.Width, msg.Height)
		}
		if a.form != nil {
			a.form.resize(msg.Width)
		}
		return a, nil
	case statusMsg:
		a.status = sysinfo.Status(msg)
		a.ready = true
		return a, nil
	case publicIPMsg:
		if a.status.PublicIP == "" && msg != "" {
			a.status.PublicIP = string(msg)
		}
		return a, nil
	}

	if a.form != nil {
		if key, ok := msg.(tea.KeyPressMsg); ok {
			return a.handleFormKey(key)
		}
		return a, a.form.update(msg)
	}

	switch msg := msg.(type) {
	case tea.KeyPressMsg:
		return a.handleKey(msg)
	case spinner.TickMsg:
		if a.task != nil {
			return a, a.task.handle(msg)
		}
	case logLineMsg, logsClosedMsg:
		if a.task != nil {
			return a, a.task.handle(msg)
		}
	case taskDoneMsg:
		if a.task != nil {
			cmd := a.task.handle(msg)
			return a, tea.Batch(cmd, collectStatus(a.scriptVersion))
		}
	}
	return a, nil
}

func (a *App) handleKey(msg tea.KeyPressMsg) (tea.Model, tea.Cmd) {
	key := strings.ToLower(msg.String())

	if a.task != nil {
		if key == "ctrl+c" {
			return a, quit()
		}
		cmd, done := a.task.handleKey(msg)
		if done {
			a.task = nil
		}
		return a, cmd
	}

	if a.toast != "" {
		a.toast = ""
	}

	switch key {
	case "ctrl+c":
		return a, quit()
	case "q":
		if len(a.stack) > 1 {
			a.pop()
			return a, nil
		}
		return a, quit()
	case "esc", "backspace":
		if len(a.stack) > 1 {
			a.pop()
		} else {
			return a, quit()
		}
	case "up", "k":
		a.move(-1)
	case "down", "j":
		a.move(1)
	case "0", "1", "2", "3", "4", "5", "6", "7", "8", "9":
		// Shell-style numeric selection: pick the row, Enter runs it. 0 targets
		// the trailing navigation row, which only exists in submenus.
		if key == "0" {
			if a.hasNavRow() {
				a.index = len(a.current().nodes)
			}
		} else if n := int(key[0] - '0'); n <= len(a.current().nodes) {
			a.index = n - 1
		}
	case "left":
		if len(a.stack) > 1 {
			a.pop()
		}
	case "right", "enter":
		return a, a.enter()
	case "l":
		a.lang = a.lang.Toggle()
		a.quote = a.lang.Hitokoto()
	case "r":
		return a, tea.Batch(collectStatus(a.scriptVersion), fetchPublicIP())
	}
	return a, nil
}

func (a *App) View() tea.View {
	if !a.sized {
		// Wait for the first size report before drawing.
		return tea.NewView("")
	}
	var content string
	switch {
	case a.form != nil:
		content = a.formScreen()
	case a.task != nil:
		content = a.task.View(a.width, a.height, a.palette, a.lang, a.iconSet)
	default:
		content = a.dashboard()
	}
	v := tea.NewView(content)
	// Fullscreen keeps the terminal clean: the shell prompt and command above
	// are hidden while the dashboard runs, and the inline renderer's stale-frame
	// stacking cannot happen.
	v.AltScreen = true
	return v
}

func (a *App) formScreen() string {
	w := a.width
	if w <= 0 {
		w = 96
	}
	if w > 100 {
		w = 100
	}
	h := a.height
	if h <= 0 {
		h = 24
	}
	out := strings.Split(a.form.View(w, a.palette, a.lang), "\n")
	for len(out) < h-1 {
		out = append(out, "")
	}
	out = append(out, a.statusBar(w))
	return strings.Join(out, "\n")
}

// dashboard renders the dashboard inside a main box pinned to the top of the
// screen, with an optional hint box below it. The layout adapts to the terminal
// so nothing overflows: optional cards drop first, then the menu scrolls. When
// the terminal is too short for a second box, the hints fall back to the inline
// bottom row.
func (a *App) dashboard() string {
	w := a.width
	if w <= 0 {
		w = 96
	}
	if w > 100 {
		w = 100
	}
	if w < 24 {
		w = 24
	}
	h := a.height
	if h <= 0 {
		h = 24
	}
	inner := w - 4
	if inner < 16 {
		inner = 16
	}

	// Two stacked boxes need 5 rows of chrome (2 + 3); below that the hints go
	// inline on the final row, which leaves room for three more body rows.
	useHintBox := h >= 12
	var budget int
	if useHintBox {
		budget = h - 5
	} else {
		budget = h - 3
	}
	if budget < 5 {
		budget = 5
	}

	tagline := a.headerTagline(inner)
	author := a.headerAuthor()
	rule := theme.Rule(inner, a.palette.Border)

	inNode := a.inNodeManagement()
	var version []string
	var info []string
	if inNode {
		info = a.nodeSection(inner)
	} else {
		version = a.versionLines(inner)
		info = a.deviceSection(inner)
	}
	quote := a.headerQuote(inner)

	navRows := 0
	if a.hasNavRow() {
		navRows = 1
	}

	// Greedy section budget. base covers the tagline, author line, the rule
	// before the menu and the menu title; one row is reserved for a menu entry.
	base := 4
	avail := budget - base - navRows - 1
	if a.toast != "" {
		avail--
	}
	if avail < 0 {
		avail = 0
	}

	take := func(cost int) bool {
		if cost > avail {
			return false
		}
		avail -= cost
		return true
	}
	// The version block is preceded by a separator rule, so it costs one extra
	// row on top of its content lines.
	showVersion := len(version) > 0 && take(len(version)+1)
	showInfo := take(len(info))
	showQuote := take(1)
	rowsAvail := 1 + avail
	if rowsAvail < 1 {
		rowsAvail = 1
	}

	items, hidden := a.menuViewport(rowsAvail, inner)
	menuTitle := " " + a.palette.Bold(a.palette.Primary, a.current().title(a.lang))
	if hidden > 0 {
		menuTitle += a.palette.Dim(fmt.Sprintf("  (+%d)", hidden))
	}

	body := []string{tagline, author}
	if showVersion {
		body = append(body, rule)
		body = append(body, version...)
	}
	if showInfo {
		body = append(body, info...)
	}
	if showQuote {
		body = append(body, quote)
	}
	body = append(body, rule, menuTitle)
	body = append(body, items...)
	if a.hasNavRow() {
		body = append(body, a.rowLine(a.onNavRow(), a.iconSet.Arrow+" "+a.navLabel(), inner))
	}

	box := theme.Box("EasySB", strings.Join(body, "\n"), w, a.palette.Border, a.palette.Primary)
	out := strings.Split(box, "\n")
	if a.toast != "" {
		out = append(out, " "+a.renderToast(w))
	}
	if useHintBox {
		out = append(out, a.hintBox(w)...)
		return strings.Join(out, "\n")
	}
	// Fullscreen: pad so the hint sits on the last row, leaving the rest of the
	// screen blank instead of letting old shell output show through.
	for len(out) < h-1 {
		out = append(out, "")
	}
	out = append(out, a.statusBar(w))
	return strings.Join(out, "\n")
}

// menuViewport renders at most limit menu rows, keeping the cursor visible, and
// reports how many items are currently out of view.
func (a *App) menuViewport(limit, inner int) ([]string, int) {
	nodes := a.current().nodes
	n := len(nodes)
	if n == 0 {
		return nil, 0
	}
	top := 0
	if n > limit {
		top = a.index - limit/2
		if a.onNavRow() {
			top = n - limit
		}
		if top < 0 {
			top = 0
		}
		if top > n-limit {
			top = n - limit
		}
	}
	end := top + limit
	if end > n {
		end = n
	}
	rows := make([]string, 0, end-top)
	for i := top; i < end; i++ {
		rows = append(rows, a.rowLine(i == a.index, a.nodeLabel(nodes[i]), inner))
	}
	return rows, n - len(rows)
}

// nodeLabel prefixes a menu entry with its icon, falling back to a bullet for
// entries that have no dedicated glyph.
func (a *App) nodeLabel(n *node) string {
	if n.icon != nil {
		return n.icon(a.iconSet) + " " + n.label(a.lang)
	}
	return a.iconSet.Bullet + " " + n.label(a.lang)
}

func (a *App) rowLine(selected bool, label string, inner int) string {
	marker := "  "
	if selected {
		marker = "▌ "
	}
	line := " " + marker + theme.Truncate(label, inner-3)
	if selected {
		return a.palette.Bold(a.palette.Primary, line)
	}
	return a.palette.Value(line)
}

func (a *App) renderToast(w int) string {
	icon := a.iconSet.Info
	col := a.palette.Primary
	if a.toastErr {
		icon = a.iconSet.Warn
		col = a.palette.Warn
	}
	return " " + a.palette.Colored(col, icon+" "+theme.Truncate(a.toast, w-4))
}

func (a *App) statusBar(w int) string {
	keys := strings.Join([]string{
		a.lang.T("hint_navigate"),
		a.lang.T("hint_enter"),
		a.lang.T("hint_back"),
		a.lang.T("hint_lang"),
		a.lang.T("hint_quit"),
	}, "  ")
	left := " " + a.palette.Dim(keys)
	right := a.palette.Label(a.lang.Code()) + " "
	gap := w - lipgloss.Width(left) - lipgloss.Width(right)
	if gap < 1 {
		gap = 1
	}
	return left + strings.Repeat(" ", gap) + right
}
