package tui

import (
	"fmt"
	"strings"

	"charm.land/bubbles/v2/spinner"
	tea "charm.land/bubbletea/v2"
	"charm.land/lipgloss/v2"

	"github.com/MinimaxFlora/EasySB/internal/i18n"
	"github.com/MinimaxFlora/EasySB/internal/icons"
	"github.com/MinimaxFlora/EasySB/internal/sysinfo"
	"github.com/MinimaxFlora/EasySB/internal/theme"
)

type statusMsg sysinfo.Status

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
	return collectStatus(a.scriptVersion)
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

func quit() tea.Cmd {
	return func() tea.Msg { return tea.Quit() }
}

func (a *App) current() *menu { return a.stack[len(a.stack)-1] }

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
// navigation row ("back" / "exit").
func (a *App) itemCount() int {
	n := len(a.current().nodes)
	if n == 0 {
		return 1
	}
	return n + 1
}

// onNavRow reports whether the cursor sits on the trailing navigation row.
func (a *App) onNavRow() bool {
	return a.index >= len(a.current().nodes)
}

// navLabel is the label of the trailing navigation row.
func (a *App) navLabel() string {
	if len(a.stack) <= 1 {
		return a.lang.T("exit")
	}
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
		// the trailing navigation row (back / exit).
		if key == "0" {
			a.index = len(a.current().nodes)
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
		return a, collectStatus(a.scriptVersion)
	}
	return a, nil
}

func (a *App) View() tea.View {
	if !a.sized {
		// Wait for the first size report before drawing. Painting an oversized
		// frame early makes the terminal scroll and leaves stale copies behind,
		// which is what produced the stacked headers.
		return tea.NewView(" ")
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
	// The menu draws inline like the shell script; only long-running tasks take
	// over the screen so their live log can scroll comfortably.
	v.AltScreen = a.task != nil
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
	out := strings.Split(a.form.View(w, a.palette, a.lang), "\n")
	out = append(out, a.statusBar(w))
	return strings.Join(out, "\n")
}

// dashboard renders the whole dashboard inside a single box that always fits
// the terminal, so the inline renderer never needs to scroll.
func (a *App) dashboard() string {
	w := a.width
	if w <= 0 {
		w = 96
	}
	if w > 100 {
		w = 100
	}
	h := a.height
	if h <= 0 {
		h = 30
	}
	inner := w - 4
	if inner < 16 {
		inner = 16
	}

	title := a.headerTitle(inner)
	author := a.headerAuthor()
	quote := a.headerQuote(inner)
	rule := theme.Rule(inner, a.palette.Border)
	status := a.statusSummary(inner)
	menuTitle := " " + a.palette.Bold(a.palette.Primary, a.current().title(a.lang))
	rows := a.menuLines(inner)

	assemble := func(withQuote, withStatus bool) []string {
		var body []string
		body = append(body, title, author)
		if withQuote {
			body = append(body, quote)
		}
		if withStatus {
			body = append(body, rule)
			body = append(body, status...)
		}
		body = append(body, rule, menuTitle)
		body = append(body, rows...)
		return body
	}

	// Budget: terminal height minus box borders (2) and the hint line (1).
	budget := h - 3
	if a.toast != "" {
		budget--
	}
	body := assemble(true, true)
	if len(body) > budget {
		body = assemble(false, true)
	}
	if len(body) > budget {
		body = assemble(false, false)
	}

	box := theme.Box("EasySB", strings.Join(body, "\n"), w, a.palette.Border, a.palette.Primary)
	out := strings.Split(box, "\n")
	if a.toast != "" {
		out = append(out, " "+a.renderToast(w))
	}
	out = append(out, a.statusBar(w))
	return strings.Join(out, "\n")
}

func (a *App) menuLines(inner int) []string {
	var rows []string
	for i, n := range a.current().nodes {
		rows = append(rows, a.rowLine(i == a.index, fmt.Sprintf("[%d] %s", i+1, n.label(a.lang)), inner))
	}
	rows = append(rows, a.rowLine(a.onNavRow(), "[0] "+a.navLabel(), inner))
	return rows
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
