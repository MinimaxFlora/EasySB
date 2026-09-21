package tui

import (
	"fmt"
	"os"
	"strings"

	"charm.land/bubbles/v2/spinner"
	tea "charm.land/bubbletea/v2"
	"charm.land/lipgloss/v2"

	"github.com/MinimaxFlora/EasySB/internal/i18n"
	"github.com/MinimaxFlora/EasySB/internal/icons"
	"github.com/MinimaxFlora/EasySB/internal/state"
	"github.com/MinimaxFlora/EasySB/internal/subscribe"
	"github.com/MinimaxFlora/EasySB/internal/sysinfo"
	"github.com/MinimaxFlora/EasySB/internal/theme"
)

type statusMsg sysinfo.Status

type App struct {
	scriptVersion string
	lang          i18n.Lang
	iconSet       icons.Set
	palette       theme.Palette
	themeAuto     bool
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
	links         *linksModel
}

func New(scriptVersion string, lang i18n.Lang) *App {
	palette, auto := paletteFromEnv()
	return &App{
		scriptVersion: scriptVersion,
		lang:          lang,
		iconSet:       icons.Detect(),
		palette:       palette,
		themeAuto:     auto,
		stack:         []*menu{buildRoot()},
		quote:         lang.Hitokoto(),
	}
}

// paletteFromEnv picks the starting palette. EASYSB_THEME, set by --theme,
// forces dark or light; otherwise the palette follows the terminal background
// detected on startup.
func paletteFromEnv() (theme.Palette, bool) {
	switch strings.ToLower(strings.TrimSpace(os.Getenv("EASYSB_THEME"))) {
	case "light":
		return theme.Light(), false
	case "dark":
		return theme.Dark(), false
	default:
		return theme.Dark(), true
	}
}

func (a *App) Init() tea.Cmd {
	cmds := []tea.Cmd{collectStatus(a.scriptVersion)}
	if a.themeAuto {
		cmds = append(cmds, requestBackground())
	}
	return tea.Batch(cmds...)
}

// requestBackground asks the terminal for its background color; the reply
// drives the light/dark palette choice.
func requestBackground() tea.Cmd {
	return func() tea.Msg { return tea.RequestBackgroundColor() }
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

// startTaskLinks is startTask for subscription work: on success the log is
// replaced by the copyable link grid.
func (a *App) startTaskLinks(title string, fn taskFunc) tea.Cmd {
	p := newProgress(title, fn)
	p.afterLinks = true
	p.resize(a.width, a.height)
	a.task = &p
	return p.Init()
}

// openSubscriptionLinks builds the per-client subscription card grid from the
// current state.
func (a *App) openSubscriptionLinks() {
	cfg := state.Load()
	if cfg.Host() == "" {
		a.setToast(a.lang.T("sub_need_domain"), true)
		return
	}
	port := cfg.SubPort
	if port == "" {
		port = state.DefaultSubPort
	}
	host := cfg.Host() + ":" + port
	items := make([]linkItem, 0, len(subscribe.Clients))
	for _, client := range subscribe.Clients {
		items = append(items, linkItem{
			label: subscriptionTitle(a.lang, client),
			meta:  host,
			desc:  clientDescription(a.lang, client),
			value: subscribe.ClientURL(cfg, client),
		})
	}
	a.links = newLinksModel(a.lang.T("sub_url"), items)
}

// subscriptionTitle is the card title for a subscription endpoint, e.g.
// "sing-box 订阅".
func subscriptionTitle(lang i18n.Lang, client subscribe.Client) string {
	switch client {
	case subscribe.ClientSingBox:
		return lang.T("links_sub_singbox")
	case subscribe.ClientMihomo:
		return lang.T("links_sub_mihomo")
	default:
		return lang.T("links_sub_v2ray")
	}
}

// openShareLinks builds the share-link card grid for the enabled protocols.
func (a *App) openShareLinks() {
	cfg := state.Load()
	if !cfg.AnyEnabled() {
		a.setToast(a.lang.T("node_all_disabled"), true)
		return
	}
	links := subscribe.ShareLinks(cfg)
	order := []string{
		state.ProtoAnyTLS,
		state.ProtoHysteria2,
		state.ProtoTUIC,
		state.ProtoVMessWSTLS,
		state.ProtoVLESSReality,
	}
	items := make([]linkItem, 0, len(links))
	next := 0
	for _, key := range order {
		if !cfg.Enabled[key] || next >= len(links) {
			continue
		}
		items = append(items, linkItem{label: state.Labels[key], meta: cfg.Host(), value: links[next]})
		next++
	}
	a.links = newLinksModel(a.lang.T("sub_links"), items)
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
	case tea.BackgroundColorMsg:
		// Follow the terminal background unless --theme pinned a palette.
		if a.themeAuto {
			if msg.IsDark() {
				a.palette = theme.Dark()
			} else {
				a.palette = theme.Light()
			}
		}
		return a, nil
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
			if a.task.done && a.task.err == nil && a.task.afterLinks {
				a.task = nil
				a.openSubscriptionLinks()
				cmd = nil
			}
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
		cmd, done := a.task.handleKey(msg, a.lang)
		if done {
			a.task = nil
		}
		return a, cmd
	}

	if a.links != nil {
		if key == "ctrl+c" {
			return a, quit()
		}
		cmd, done := a.links.handleKey(msg, a.lang)
		if done {
			a.links = nil
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
		// Q always quits, at any depth. Esc and the navigation row are the
		// ways back to the parent menu.
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
		return a, collectStatus(a.scriptVersion)
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
	case a.links != nil:
		content = a.links.View(a.width, a.height, a.palette, a.lang, a.iconSet)
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
	w, h := a.frameWidth(), a.height
	if h <= 0 {
		h = 24
	}
	body := strings.Split(a.form.View(w, a.palette, a.lang), "\n")
	hint := a.lang.T("form_confirm") + "  " + a.lang.T("form_cancel")
	return framePanel(a.palette, a.lang, w, h, body, a.palette.Dim(hint))
}

// frameWidth is the shared panel width: the terminal width capped at 100 so
// every screen lines up with the main dashboard.
func (a *App) frameWidth() int {
	return panelWidth(a.width)
}

// dashboard renders the dashboard inside a single framed panel with full-width
// section dividers. Decorative blocks (logo, contact block, quote) and status
// sections drop out as the terminal shrinks, and the menu scrolls, so the panel
// never grows taller than the screen.
func (a *App) dashboard() string {
	w := a.frameWidth()
	h := a.height
	if h <= 0 {
		h = 24
	}
	inner := w - 4
	if inner < 16 {
		inner = 16
	}

	// A hint box costs two extra rows of chrome. It is used only when it can
	// still show at least as much content as the inline hints, so a short but
	// not tiny terminal keeps its panels instead of sacrificing them to the box.
	inNode := a.inNodeManagement()
	nav := a.hasNavRow()
	totalItems := len(a.current().nodes)
	if totalItems < 1 {
		totalItems = 1
	}

	logoLines := a.logoLines(inner)
	overviewRows := a.overviewRows(inner)
	deviceLines := a.deviceSection(inner)[1:]
	nodeLines := a.nodeSection(inner)[1:]

	// layout describes which optional blocks are on screen; its cost is the
	// exact number of body rows it renders. Every block is separated by one
	// blank line and every menu item trails one, while rows inside a panel stay
	// tight, so the whole dashboard shares a single vertical rhythm.
	type layout struct {
		logo     bool
		overview bool
		device   bool
		node     bool
		items    int
		quote    bool
	}
	cost := func(l layout) int {
		n := 2 // tagline + hairline rule
		if l.logo {
			n += len(logoLines)
		}
		firstSection := true
		section := func(rows int) {
			n++ // blank above the divider
			if !firstSection {
				n++ // section divider
			}
			firstSection = false
			n += 2 + rows // title + blank + rows
		}
		if l.node {
			section(len(nodeLines))
		} else {
			if l.overview {
				section(len(overviewRows))
			}
			if l.device {
				section(len(deviceLines))
			}
		}
		n++ // blank above the menu divider
		n++ // menu divider
		n++ // menu title
		if l.items > 0 {
			n++              // blank under the menu title
			n += l.items     // entries
			n += l.items - 1 // blanks between entries
		}
		if nav {
			n += 2 // blank + navigation row
		}
		if l.quote {
			n += 2 // blank + quote
		}
		return n
	}
	// solve drops the least critical blocks first until the layout fits, then
	// trims menu entries as a last resort.
	solve := func(budget int) layout {
		l := layout{
			logo:     len(logoLines) > 0,
			overview: !inNode,
			device:   !inNode,
			node:     inNode,
			items:    totalItems,
			quote:    true,
		}
		// Drop the decorative blocks first, then the secondary device card, so
		// the status overview and the full menu survive the longest.
		drops := []func(*layout){
			func(l *layout) { l.quote = false },
			func(l *layout) { l.logo = false },
			func(l *layout) { l.device = false },
			func(l *layout) { l.overview = false },
			func(l *layout) { l.node = false },
		}
		for i := 0; cost(l) > budget; {
			if i < len(drops) {
				drops[i](&l)
				i++
				continue
			}
			if l.items > 1 {
				l.items--
				continue
			}
			break
		}
		return l
	}

	// Every screen renders the same fixed frame: the body keeps a constant
	// height and the hint box is pinned to the bottom, so moving between the
	// menu and a subpage never resizes the panel. On terminals too short to
	// spare the box, the hints fall back to a single bottom line.
	useHintBox := hintRows(h) > 0
	budget := h - 5
	if !useHintBox {
		budget = h - 3
	}
	if budget < 3 {
		budget = 3
	}
	l := solve(budget)

	type row struct {
		text  string
		sep   bool
		rule  bool
		blank bool
	}
	var rows []row
	add := func(text string) { rows = append(rows, row{text: text}) }
	blank := func() { rows = append(rows, row{blank: true}) }
	divider := func() { rows = append(rows, row{sep: true}) }

	if l.logo {
		for _, line := range logoLines {
			add(line)
		}
	}
	add(a.taglineLine(inner))
	rows = append(rows, row{rule: true})

	// The tagline rule already closes the header, so the first section skips its
	// divider; every section keeps one blank line under its title.
	firstSection := true
	section := func(titleKey string, lines []string) {
		blank()
		if !firstSection {
			divider()
		}
		firstSection = false
		add(a.sectionTitle(titleKey))
		blank()
		for _, line := range lines {
			add(line)
		}
	}
	if l.node {
		section("panel_node", nodeLines)
	} else {
		if l.overview {
			section("panel_overview", overviewRows)
		}
		if l.device {
			section("panel_device", deviceLines)
		}
	}

	blank()
	divider()
	menuTitle := "  " + a.palette.Bold(a.palette.Primary, a.current().title(a.lang))
	descCol := a.menuDescColumn(inner, a.menuLabelColumn())
	cursorWidth := a.menuCursorWidth(inner)
	items, hidden := a.menuViewport(l.items, inner, descCol, cursorWidth)
	if hidden > 0 {
		menuTitle += a.palette.Dim(fmt.Sprintf("  (+%d)", hidden))
	}
	add(menuTitle)
	if len(items) > 0 {
		blank()
	}
	for i, item := range items {
		if i > 0 {
			blank()
		}
		add(item)
	}
	if nav {
		blank()
		add(a.rowLine(a.onNavRow(), a.iconSet.Arrow+" "+a.navLabel(), inner, cursorWidth))
	}

	if l.quote {
		blank()
		add(a.quoteLine(inner))
	}

	// Safety net for very short terminals: if even the tightest layout overflows,
	// reclaim blank rows from the bottom until it fits. The frame stays intact.
	for len(rows) > budget {
		idx := -1
		for i := len(rows) - 1; i >= 0; i-- {
			if rows[i].blank {
				idx = i
				break
			}
		}
		if idx < 0 {
			break
		}
		rows = append(rows[:idx], rows[idx+1:]...)
	}

	// Spare rows are parked just above the quote, which keeps it pinned near the
	// closing border; the remainder fills the bottom of the frame. The body is
	// always padded to the exact height so no screen changes the panel size.
	padBefore := -1
	if l.quote && len(rows) > 0 {
		padBefore = len(rows) - 1
		if padBefore > 0 && rows[padBefore-1].blank {
			padBefore--
		}
	}
	spare := budget - len(rows)
	if spare < 0 {
		spare = 0
	}

	out := []string{theme.TopRule(w, a.palette.Border)}
	pad := func() { out = append(out, theme.FrameLine("", w, a.palette.Border)) }
	for i, r := range rows {
		if i == padBefore {
			for n := 0; n < spare; n++ {
				pad()
			}
			spare = 0
		}
		switch {
		case r.blank:
			pad()
		case r.sep:
			out = append(out, theme.SectionRule(w, a.palette.Border))
		case r.rule:
			out = append(out, theme.FrameRule(w, a.palette.Border))
		default:
			out = append(out, theme.FrameLine(r.text, w, a.palette.Border))
		}
	}
	for n := 0; n < spare; n++ {
		pad()
	}
	// Keep the frame rectangular even when the tightest layout still overflows.
	if len(out) > budget+1 {
		out = out[:budget+1]
	}
	out = append(out, theme.BottomRule(w, a.palette.Border))

	hint := a.palette.Dim(a.dashboardHint())
	if a.toast != "" {
		hint = a.renderToast(w - 4)
	}
	if useHintBox {
		out = append(out, a.hintBox(hint, w)...)
		return strings.Join(out, "\n")
	}
	// Fullscreen: pad so the hint sits on the last row, leaving the rest of the
	// screen blank instead of letting old shell output show through.
	if len(out) > h-1 {
		out = out[:h-1]
	}
	for len(out) < h-1 {
		out = append(out, "")
	}
	out = append(out, a.hintLine(hint, w))
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

// menuDescColumn returns the column where the root menu descriptions start.
// The label column stays pinned to the left; the description block is centered
// in the panel so the free space is balanced on both sides of it.
func (a *App) menuDescColumn(inner, labelCol int) int {
	min := labelCol + 3
	if a.current().id != "root" {
		return min
	}
	maxDesc := 0
	for _, n := range a.current().nodes {
		if n.desc == nil {
			continue
		}
		if w := lipgloss.Width(n.desc(a.lang)); w > maxDesc {
			maxDesc = w
		}
	}
	if maxDesc == 0 {
		return min
	}
	col := (inner - maxDesc) / 2
	if col < min {
		col = min
	}
	return col
}

// menuViewport renders at most limit menu rows, keeping the cursor visible, and
// reports how many items are currently out of view.
func (a *App) menuViewport(limit, inner, descCol, cursorWidth int) ([]string, int) {
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
		rows = append(rows, a.menuRow(i == a.index, nodes[i], inner, descCol, cursorWidth))
	}
	return rows, n - len(rows)
}

// menuRowParts lays out one entry's static text: the label padded out to the
// description column (or truncated on compact submenu rows) and the description
// itself. The selection marker is added by menuRow.
func (a *App) menuRowParts(n *node, inner, descCol int) (string, string) {
	label := a.nodeLabel(n)
	desc := ""
	if n.desc != nil {
		desc = n.desc(a.lang)
	}
	if desc != "" {
		gap := descCol - 3 - lipgloss.Width(label)
		if gap < 2 {
			gap = 2
		}
		descWidth := inner - 3 - lipgloss.Width(label) - gap
		if descWidth >= 4 {
			return label + strings.Repeat(" ", gap), theme.Truncate(desc, descWidth)
		}
	}
	return theme.Truncate(label, inner-3), ""
}

// menuCursorWidth returns the length every selection bar is padded to. The bar
// spans the full inner width so the cursor keeps one size while moving.
func (a *App) menuCursorWidth(inner int) int {
	return inner
}

// menuRow renders one menu entry. The main menu pads its labels into a column
// and follows them with a short one-line description; submenus stay compact.
func (a *App) menuRow(selected bool, n *node, inner, descCol, cursorWidth int) string {
	marker := "  "
	if selected {
		marker = "▌ "
	}
	head, desc := a.menuRowParts(n, inner, descCol)
	line := " " + marker + head
	if selected {
		// The bar spans the whole row and is padded to the longest entry, so the
		// cursor does not change length as it moves through the menu.
		return a.palette.SelectedRow(theme.Pad(line+desc, cursorWidth))
	}
	if desc == "" {
		return a.palette.Bold(a.palette.Text, line)
	}
	return a.palette.Bold(a.palette.Text, line) + a.palette.Dim(desc)
}

// nodeLabel prefixes a menu entry with its icon, falling back to a bullet for
// entries that have no dedicated glyph.
func (a *App) nodeLabel(n *node) string {
	if n.icon != nil {
		return n.icon(a.iconSet) + " " + n.label(a.lang)
	}
	return a.iconSet.Bullet + " " + n.label(a.lang)
}

func (a *App) rowLine(selected bool, label string, inner, cursorWidth int) string {
	marker := "  "
	if selected {
		marker = "▌ "
	}
	line := " " + marker + theme.Truncate(label, inner-3)
	if selected {
		return a.palette.SelectedRow(theme.Pad(line, cursorWidth))
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

// dashboardHint is the key list shown in the pinned hint box on the main menu.
func (a *App) dashboardHint() string {
	return strings.Join([]string{
		a.lang.T("hint_navigate"),
		a.lang.T("hint_enter"),
		a.lang.T("hint_back"),
		a.lang.T("hint_lang"),
		a.lang.T("hint_quit"),
	}, "  ")
}
