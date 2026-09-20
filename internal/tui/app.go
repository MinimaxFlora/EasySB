package tui

import (
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
	toast         string
	toastErr      bool
	task          *progressModel
}

func New(scriptVersion string, lang i18n.Lang) *App {
	return &App{
		scriptVersion: scriptVersion,
		lang:          lang,
		iconSet:       icons.Detect(),
		palette:       theme.Dark(),
		stack:         []*menu{buildRoot()},
	}
}

func (a *App) Init() tea.Cmd {
	return collectStatus(a.scriptVersion)
}

func (a *App) Snapshot(width, height int) string {
	a.width, a.height = width, height
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
	n := len(a.current().nodes)
	if n == 0 {
		return
	}
	a.index = (a.index + d + n) % n
}

func (a *App) selected() *node {
	nodes := a.current().nodes
	if len(nodes) == 0 {
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

func (a *App) Update(msg tea.Msg) (tea.Model, tea.Cmd) {
	switch msg := msg.(type) {
	case tea.WindowSizeMsg:
		a.width, a.height = msg.Width, msg.Height
		if a.task != nil {
			a.task.resize(msg.Width, msg.Height)
		}
		return a, nil
	case statusMsg:
		a.status = sysinfo.Status(msg)
		a.ready = true
		return a, nil
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
	case "left":
		if len(a.stack) > 1 {
			a.pop()
		}
	case "right", "enter":
		return a, a.enter()
	case "l":
		a.lang = a.lang.Toggle()
	case "r":
		return a, collectStatus(a.scriptVersion)
	}
	return a, nil
}

func (a *App) View() tea.View {
	content := a.dashboard()
	if a.task != nil {
		content = a.task.View(a.width, a.height, a.palette, a.lang, a.iconSet)
	}
	v := tea.NewView(content)
	v.AltScreen = true
	return v
}

func (a *App) dashboard() string {
	w := a.width
	if w <= 0 {
		w = 96
	}
	h := a.height
	if h <= 0 {
		h = 32
	}

	header := a.headerLines(w)
	bodyHeight := h - len(header) - 3
	if bodyHeight < 6 {
		bodyHeight = 6
	}

	var body []string
	if w < 78 {
		body = append(body, a.leftPanel(w-2)...)
		body = append(body, "")
		body = append(body, a.rightPanel(w-2)...)
	} else {
		lw := int(float64(w) * 0.32)
		if lw < 24 {
			lw = 24
		}
		if lw > 34 {
			lw = 34
		}
		rw := w - lw - 2
		body = mergeColumns(a.leftPanel(lw), a.rightPanel(rw), lw, "  ")
	}
	for len(body) < bodyHeight {
		body = append(body, "")
	}

	out := make([]string, 0, len(header)+len(body)+3)
	out = append(out, header...)
	out = append(out, body...)
	if a.toast != "" {
		out = append(out, a.renderToast(w))
	} else {
		out = append(out, "")
	}
	out = append(out, theme.Rule(w, a.palette.Border))
	out = append(out, a.statusBar(w))
	return strings.Join(out, "\n")
}

func (a *App) headerLines(w int) []string {
	bannerWidth := w
	if bannerWidth > 76 {
		bannerWidth = 76
	}
	lines := strings.Split(a.renderBanner(bannerWidth), "\n")
	lines = append(lines, "")
	lines = append(lines, a.renderVersions(w)...)
	lines = append(lines, "")
	return lines
}

func (a *App) leftPanel(width int) []string {
	inner := width - 4
	if inner < 8 {
		inner = 8
	}
	var rows []string
	for i, n := range a.current().nodes {
		selected := i == a.index
		marker := "  "
		if selected {
			marker = "▌ "
		}
		icon := ""
		if n.icon != nil {
			icon = n.icon(a.iconSet) + " "
		}
		raw := theme.Truncate(marker+icon+n.label(a.lang), inner)
		if selected {
			rows = append(rows, a.palette.Bold(a.palette.Primary, raw))
		} else {
			rows = append(rows, a.palette.Value(raw))
		}
	}
	box := theme.Box(a.current().title(a.lang), strings.Join(rows, "\n"), width, a.palette.Border, a.palette.Primary)
	return strings.Split(box, "\n")
}

func (a *App) rightPanel(width int) []string {
	inner := width - 4
	if inner < 10 {
		inner = 10
	}
	content := strings.Join(a.statusLines(inner), "\n")
	box := theme.Box(a.lang.T("status_overview"), content, width, a.palette.Border, a.palette.Primary)
	return strings.Split(box, "\n")
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

func mergeColumns(left, right []string, leftWidth int, gap string) []string {
	n := len(left)
	if len(right) > n {
		n = len(right)
	}
	out := make([]string, n)
	for i := 0; i < n; i++ {
		l := ""
		if i < len(left) {
			l = left[i]
		}
		r := ""
		if i < len(right) {
			r = right[i]
		}
		out[i] = theme.Pad(l, leftWidth) + gap + r
	}
	return out
}
