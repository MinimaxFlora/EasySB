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

// dashboard renders the dashboard inside a single framed panel with full-width
// section dividers. Decorative blocks (logo, contact block, quote) and status
// sections drop out as the terminal shrinks, and the menu scrolls, so the panel
// never grows taller than the screen.
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

	// Two stacked panels need five rows of chrome; below that the hints go
	// inline on the final row, which leaves room for three more body rows.
	useHintBox := h >= 14
	var budget int
	if useHintBox {
		budget = h - 5
	} else {
		budget = h - 3
	}
	if a.toast != "" {
		budget--
	}
	if budget < 3 {
		budget = 3
	}

	inNode := a.inNodeManagement()
	navRows := 0
	if a.hasNavRow() {
		navRows = 1
	}
	totalItems := len(a.current().nodes)

	// Required rows: tagline, hairline rule, menu divider, menu title, one menu
	// entry and the optional navigation row.
	used := 5 + navRows
	menuRows := 1

	showOverview, showDevice, showNode := false, false, false
	if inNode {
		if used+9 <= budget {
			used += 9
			showNode = true
		}
	} else {
		if used+5 <= budget {
			used += 5
			showOverview = true
		}
		if used+5 <= budget {
			used += 5
			showDevice = true
		}
	}
	for menuRows < totalItems && used+1 <= budget {
		used++
		menuRows++
	}
	showQuote := used+1 <= budget
	if showQuote {
		used++
	}
	showContact := used+4 <= budget
	if showContact {
		used += 4
	}
	var logo []string
	if lines := a.logoLines(inner); lines != nil && used+len(lines) <= budget {
		used += len(lines)
		logo = lines
	}
	leftover := budget - used

	type row struct {
		text    string
		sep     bool
		blankOK bool
	}
	var rows []row
	addText := func(s string, blankOK bool) { rows = append(rows, row{text: s, blankOK: blankOK}) }
	addSection := func(titleKey string, lines []string) {
		rows = append(rows, row{sep: true})
		addText(a.sectionTitle(titleKey), len(lines) > 0)
		for i, l := range lines {
			addText(l, i == len(lines)-1)
		}
	}

	for i, l := range logo {
		addText(l, i == len(logo)-1)
	}
	for i, l := range a.taglineLines(inner) {
		addText(l, i == 1)
	}
	if showContact {
		lines := a.contactLines()
		for i, l := range lines {
			addText(l, i == len(lines)-1)
		}
	}
	if showOverview {
		addSection("panel_overview", a.overviewRows(inner))
	}
	if showDevice {
		addSection("panel_device", a.deviceSection(inner)[1:])
	}
	if showNode {
		addSection("panel_node", a.nodeSection(inner)[1:])
	}

	rows = append(rows, row{sep: true})
	menuTitle := "  " + a.palette.Bold(a.palette.Primary, a.current().title(a.lang))
	items, hidden := a.menuViewport(menuRows, inner, a.menuLabelColumn())
	if hidden > 0 {
		menuTitle += a.palette.Dim(fmt.Sprintf("  (+%d)", hidden))
	}
	addText(menuTitle, true)
	for i, l := range items {
		addText(l, i == len(items)-1)
	}
	if a.hasNavRow() {
		addText(a.rowLine(a.onNavRow(), a.iconSet.Arrow+" "+a.navLabel(), inner), true)
	}
	if showQuote {
		addText(a.quoteLine(inner), false)
	}

	out := []string{theme.TopRule(w, a.palette.Border)}
	for i, r := range rows {
		if r.sep {
			out = append(out, theme.SectionRule(w, a.palette.Border))
			continue
		}
		out = append(out, theme.FrameLine(r.text, w, a.palette.Border))
		if r.blankOK && leftover > 0 && i < len(rows)-1 {
			out = append(out, theme.FrameLine("", w, a.palette.Border))
			leftover--
		}
	}
	out = append(out, theme.BottomRule(w, a.palette.Border))

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

// menuLabelColumn returns the column at which root menu descriptions start so
// they all line up behind the widest label.
func (a *App) menuLabelColumn() int {
	width := 0
	for _, n := range a.current().nodes {
		if w := lipgloss.Width(a.nodeLabel(n)); w > width {
			width = w
		}
	}
	return width + 3
}

// menuViewport renders at most limit menu rows, keeping the cursor visible, and
// reports how many items are currently out of view.
func (a *App) menuViewport(limit, inner, labelCol int) ([]string, int) {
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
		rows = append(rows, a.menuRow(i == a.index, nodes[i], inner, labelCol))
	}
	return rows, n - len(rows)
}

// menuRow renders one menu entry. The main menu pads its labels into a column
// and follows them with a short one-line description; submenus stay compact.
func (a *App) menuRow(selected bool, n *node, inner, labelCol int) string {
	marker := "  "
	if selected {
		marker = "▌ "
	}
	label := a.nodeLabel(n)

	desc := ""
	if a.current().id == "root" && n.desc != nil {
		desc = n.desc(a.lang)
	}
	if desc == "" {
		line := " " + marker + theme.Truncate(label, inner-3)
		if selected {
			return a.palette.Bold(a.palette.Primary, line)
		}
		return a.palette.Bold(a.palette.Text, line)
	}

	gap := labelCol - lipgloss.Width(label)
	if gap < 2 {
		gap = 2
	}
	descWidth := inner - 3 - lipgloss.Width(label) - gap
	if descWidth < 4 {
		descWidth = 4
	}
	line := " " + marker + label + strings.Repeat(" ", gap)
	d := theme.Truncate(desc, descWidth)
	if selected {
		// Keep the selected label highlighted while the hint stays muted.
		return a.palette.Bold(a.palette.Primary, line) + a.palette.Dim(d)
	}
	return a.palette.Bold(a.palette.Text, line) + a.palette.Dim(d)
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
	right := a.palette.Label(a.lang.Code()) + " "
	rightW := lipgloss.Width(right)
	availLeft := w - rightW - 1
	if availLeft < 1 {
		availLeft = 1
	}
	left := " " + a.palette.Dim(theme.Truncate(keys, maxInt(0, availLeft-1)))
	gap := w - lipgloss.Width(left) - rightW
	if gap < 1 {
		gap = 1
	}
	return left + strings.Repeat(" ", gap) + right
}
