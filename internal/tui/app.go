package tui

import (
	"context"
	"fmt"
	"os"
	"strings"

	"charm.land/bubbles/v2/spinner"
	tea "charm.land/bubbletea/v2"
	"charm.land/lipgloss/v2"

	"github.com/MinimaxFlora/EasySB/internal/bbr"
	"github.com/MinimaxFlora/EasySB/internal/i18n"
	"github.com/MinimaxFlora/EasySB/internal/icons"
	"github.com/MinimaxFlora/EasySB/internal/prefs"
	"github.com/MinimaxFlora/EasySB/internal/service"
	"github.com/MinimaxFlora/EasySB/internal/subscribe"
	"github.com/MinimaxFlora/EasySB/internal/sysinfo"
	"github.com/MinimaxFlora/EasySB/internal/theme"
	"github.com/MinimaxFlora/EasySB/internal/ui"
	"github.com/MinimaxFlora/EasySB/internal/user"
)

type statusMsg sysinfo.Status

type App struct {
	scriptVersion string
	lang          i18n.Lang
	iconSet       icons.Set
	skin          theme.Skin
	dark          bool
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
	// section is the root entry the panel is standing in, empty on the main
	// menu. It is set when a root entry is entered and cleared on the way back.
	section string
	task    *progressModel
	form    *formModel
	links   *linksModel
	// system is the system information screen. It replaces the body of the frame
	// while it is open, so the status strip and the key hints stay in place.
	system *systemModel
	// accounts is the snapshot the account menus render from; it is refreshed
	// when the section is entered and after every task.
	accounts []user.User
	// bbrVersions is the published kernel list the BBR section renders from, with
	// bbrStatus as the local half of the reading: fetched when the list is opened.
	bbrVersions        []bbr.Release
	bbrVersionsErr     error
	bbrVersionsLoading bool
	bbrStatus          bbr.Status
	// prefsPath is where the interface choices are remembered. It is a field so
	// the tests can point it at a temporary file instead of /etc/sing-box.
	prefsPath string
}

// New builds the application. Interface choices the operator made earlier are
// already in the environment by the time this runs: main applies the preferences
// file only where no flag or exported variable spoke.
func New(scriptVersion string, lang i18n.Lang) *App {
	skin, dark, auto := skinFromEnv()
	a := &App{
		scriptVersion: scriptVersion,
		lang:          lang,
		iconSet:       icons.Detect(),
		themeAuto:     auto,
		stack:         []*menu{buildRoot()},
		quote:         lang.Hitokoto(),
		prefsPath:     prefs.Path(),
	}
	a.setSkin(skin, dark)
	return a
}

// remember stores the interface choices so the next run starts where this one
// left off. It is called from the actions that represent a decision, never from
// the automatic palette detection, which would look like a decision next time.
func (a *App) remember() {
	if a.prefsPath == "" {
		return
	}
	theme := ""
	if !a.themeAuto {
		if a.dark {
			theme = "dark"
		} else {
			theme = "light"
		}
	}
	_ = prefs.Prefs{
		Skin:  a.skin.ID,
		Theme: theme,
		Icons: a.iconSet.ID,
		Lang:  string(a.lang),
	}.Save(a.prefsPath)
}

// setSkin resolves the skin for a terminal background and keeps the flat palette
// the older screens use in step with it.
func (a *App) setSkin(skin theme.Skin, dark bool) {
	a.skin = skin
	a.dark = dark
	a.palette = skin.Style(dark).Palette
}

// lockLook records a manual choice: the palette stops following the terminal
// background once the operator has picked one.
func (a *App) lockLook() { a.themeAuto = false }

// setDark switches the palette to a dark or light background.
func (a *App) setDark(dark bool) {
	a.lockLook()
	a.setSkin(a.skin, dark)
}

// setIcons swaps the marker palette.
func (a *App) setIcons(set icons.Set) { a.iconSet = set }

// openSystem and closeSystem enter and leave the system information screen.
func (a *App) openSystem() {
	a.system = newSystemModel(a)
	a.section = "system"
}

func (a *App) closeSystem() {
	a.system = nil
	a.section = ""
}

// style is the current skin resolved for the current background.
func (a *App) style() theme.Style { return a.skin.Style(a.dark) }

// skinFromEnv picks the starting look. EASYSB_SKIN, set by --skin, chooses the
// skin; EASYSB_THEME, set by --theme, forces dark or light. Without either the
// palette follows the terminal background detected on startup.
func skinFromEnv() (theme.Skin, bool, bool) {
	skin, ok := theme.SkinByID(strings.TrimSpace(os.Getenv("EASYSB_SKIN")))
	if !ok {
		skin = theme.DefaultSkin()
	}
	switch strings.ToLower(strings.TrimSpace(os.Getenv("EASYSB_THEME"))) {
	case "light":
		return skin, false, false
	case "dark":
		return skin, true, false
	default:
		return skin, true, true
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

// Snapshot renders the current screen headlessly, which is what --render prints.
func (a *App) Snapshot(width, height int) string {
	a.width, a.height = width, height
	a.sized = true
	a.status = sysinfo.Collect(a.scriptVersion)
	a.ready = true
	if a.task != nil {
		// A task owns the screen while it runs, so a rendered frame is the task's.
		return a.task.View(a.width, a.height, a.statusStrip(a.frameWidth()), a.style(), a.lang, a.iconSet)
	}
	return a.dashboard()
}

// SnapshotScreen is Snapshot for one named screen, so a layout can be inspected
// without walking the menus. Any root entry that has a submenu can be named, on top of
// the screens that open their own model. Unknown names fall back to the dashboard.
func (a *App) SnapshotScreen(screen string, width, height int) string {
	if screen != "system" && a.enterSection(screen) {
		// The BBR 看板 reads the local state when the section is entered. A
		// rendered screen has no event loop to deliver that reading, so it takes
		// one here; otherwise it would only ever draw the placeholder.
		if screen == "bbr" {
			a.bbrStatus = bbrStatusNow()
		}
		return a.Snapshot(width, height)
	}
	switch screen {
	case "system":
		a.openSystem()
	case "bbr-qdisc":
		a.push(buildBBR())
		a.section = "bbr"
		a.push(buildQdisc())
	case "bbr-versions":
		a.push(buildBBR())
		a.section = "bbr"
		a.bbrStatus = bbrStatusNow()
		// The list is fetched from the network when it is opened. A rendered
		// screen shows the layout, so it takes a sample list instead of an empty
		// one, which would only ever draw the loading placeholder.
		a.bbrVersions = previewReleases()
		a.push(a.bbrVersionsMenu())
	case "task":
		// The task screen is where every action lands, and its download bar only
		// exists while a download is in flight, so a rendered frame takes a sample
		// reading rather than an idle one.
		p := newProgress(a.lang.T("kernel_installing"), func(context.Context, *taskReporter) error { return nil })
		for _, line := range previewTaskLog() {
			p.appendLog(line)
		}
		p.setDownload(previewDownload())
		p.resize(a.width, a.height)
		a.task = p
	}
	return a.Snapshot(width, height)
}

// previewTaskLog is the sample output of a rendered task screen.
func previewTaskLog() []string {
	return []string{
		"$ " + service.Command("restart"),
		"write " + sysinfo.ConfigJSON,
		"配置校验通过",
		"部署完成，服务已启动",
	}
}

// previewDownload is the sample download reading of a rendered task screen.
func previewDownload() (string, int64, int64) {
	return "easysb-linux-amd64", 12 << 20, 29 << 20
}

// enterSection pushes the submenu of a root entry by id, so a page can be rendered by
// name. It reports whether the entry exists and has a submenu to stand in.
func (a *App) enterSection(id string) bool {
	for _, n := range buildRoot().nodes {
		if n.id != id || n.sub == nil {
			continue
		}
		a.push(n.sub)
		a.section = id
		return true
	}
	return false
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
	if len(a.stack) == 1 {
		a.section = ""
	}
}

// moveRows moves the cursor one row. On the main menu the entries are drawn in
// two columns, so a row is one column slot: moving by entry there would walk the
// cursor sideways into the other column halfway down the list.
func (a *App) moveRows(d int) {
	n := a.itemCount()
	if n == 0 {
		return
	}
	if a.menuColumns() < 2 {
		a.index = (a.index + d + n) % n
		return
	}
	start, height := a.columnSpan(a.index)
	a.index = start + (a.index-start+d+height)%height
}

// moveColumn hops to the same row of the neighbouring column, staying in the last
// row when the column it lands on is shorter.
func (a *App) moveColumn(d int) {
	half := a.colHalf()
	if a.index < half {
		if d < 0 {
			return
		}
		height := a.itemCount() - half
		a.index = half + min(a.index, height-1)
		return
	}
	if d > 0 {
		return
	}
	a.index = min(a.index-half, half-1)
}

// colHalf is the number of rows in the left column of the main menu; the left
// column takes the extra row when the count is odd.
func (a *App) colHalf() int {
	return (a.itemCount() + 1) / 2
}

// columnSpan is the first index and the row count of the column holding i.
func (a *App) columnSpan(i int) (start, height int) {
	half := a.colHalf()
	if i < half {
		return 0, half
	}
	return half, a.itemCount() - half
}

// menuColumns reports how many columns the current menu is drawn in. Only the main
// menu uses two, and only while its card is wide enough for them.
func (a *App) menuColumns() int {
	if a.sectionID() != "" || len(a.current().nodes) == 0 {
		return 1
	}
	if (ui.InnerWidth(a.style(), a.frameWidth())-1)/2 < 16 {
		return 1
	}
	return 2
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
	// Entering a root entry is what decides the current section, which is what gives a
	// page its 看板. Only an entry that opens a page counts: an entry that runs an
	// action in place would otherwise leave the frame showing that section's 看板 above
	// a menu it does not own, with Esc quitting the panel instead of walking back.
	if a.current().id == "root" && n.sub != nil {
		a.section = n.id
	}
	if n.sub != nil {
		a.push(n.sub)
		return a.sectionRefresh()
	}
	if n.action != nil {
		return n.action(a)
	}
	return nil
}

func (a *App) startTask(title string, fn taskFunc) tea.Cmd {
	p := newProgress(title, fn)
	p.resize(a.width, a.height)
	a.task = p
	return p.Init()
}

// startTaskQR is startTask for the subscription QR codes: the log is a picture,
// so the copy key is hidden.
func (a *App) startTaskQR(title string, fn taskFunc) tea.Cmd {
	p := newProgress(title, fn)
	p.noCopy = true
	p.resize(a.width, a.height)
	a.task = p
	return p.Init()
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
			a.setSkin(a.skin, msg.IsDark())
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
	case bbrVersionsMsg:
		a.applyBBRVersions(msg)
		return a, nil
	case bbrStatusMsg:
		a.bbrStatus = msg.status
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
			if a.task.done {
				// The account file is what the account menus render from, so the
				// snapshot is refreshed as soon as a task finishes; a section whose
				// 看板 reads the machine (BBR) takes its reading again too, or the
				// page would keep showing what it said before the task ran.
				a.loadAccounts()
				return a, tea.Batch(cmd, collectStatus(a.scriptVersion), a.sectionRefresh())
			}
			return a, tea.Batch(cmd, collectStatus(a.scriptVersion))
		}
	}
	return a, nil
}

func (a *App) handleKey(msg tea.KeyPressMsg) (tea.Model, tea.Cmd) {
	raw := msg.String()
	key := strings.ToLower(raw)

	// Upper-case Q quits the whole program from any screen that is not a text
	// field; lower-case q and Esc step back to the parent menu.
	if raw == "Q" || key == "ctrl+c" {
		return a, quit()
	}

	if a.task != nil {
		cmd, done := a.task.handleKey(msg, a.lang)
		if done {
			a.task = nil
		}
		return a, cmd
	}

	if a.links != nil {
		cmd, done := a.links.handleKey(msg, a.lang)
		if done {
			a.links = nil
		}
		return a, cmd
	}

	// The system screen owns a few keys of its own and lets the rest fall through
	// to the global shortcuts below.
	if a.system != nil {
		if cmd, handled := a.system.handleKey(msg, a); handled {
			return a, cmd
		}
	}

	if a.toast != "" {
		a.toast = ""
	}

	switch key {
	case "q":
		// On the menu tree q quits; inside the task/link panels it steps back.
		// Upper-case Q quits from anywhere (handled above).
		return a, quit()
	case "esc", "backspace":
		if len(a.stack) > 1 {
			a.pop()
		} else {
			return a, quit()
		}
	case "up", "k":
		a.moveRows(-1)
	case "down", "j":
		a.moveRows(1)
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
		// On the two-column main menu the arrows move between columns; below
		// that width, and in every submenu, left is the way back.
		if a.menuColumns() > 1 {
			a.moveColumn(-1)
		} else if len(a.stack) > 1 {
			a.pop()
		}
	case "right":
		if a.menuColumns() > 1 {
			a.moveColumn(1)
		} else {
			return a, a.enter()
		}
	case "enter":
		return a, a.enter()
	case "l":
		a.lang = a.lang.Toggle()
		a.quote = a.lang.Hitokoto()
		a.remember()
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
		content = a.task.View(a.width, a.height, a.statusStrip(a.frameWidth()), a.style(), a.lang, a.iconSet)
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

// menuLabelColumn returns the column at which menu descriptions start so they all
// line up behind the widest numbered label.
func (a *App) menuLabelColumn() int {
	width := 0
	for i, n := range a.current().nodes {
		if w := lipgloss.Width(a.numberedLabel(i, n)); w > width {
			width = w
		}
	}
	if a.hasNavRow() {
		if w := lipgloss.Width(a.numberedLabel(len(a.current().nodes), nil)); w > width {
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
		rows = append(rows, a.menuRow(i == a.index, i, nodes[i], inner, descCol, cursorWidth))
	}
	return rows, n - len(rows)
}

// menuRowParts lays out one entry's static text: the label padded out to the
// description column (or truncated on compact submenu rows) and the description
// itself. The selection marker is added by menuRow.
func (a *App) menuRowParts(i int, n *node, inner, descCol int) (string, string) {
	label := a.numberedLabel(i, n)
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
func (a *App) menuRow(selected bool, i int, n *node, inner, descCol, cursorWidth int) string {
	marker := "  "
	if selected {
		marker = "▌ "
	}
	head, desc := a.menuRowParts(i, n, inner, descCol)
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

// numberTag is the bracket in front of every menu entry: entries are picked by
// number as well as by cursor, which is how the entries stay countable once the
// list is longer than a screen.
func (a *App) numberTag(i int) string {
	return fmt.Sprintf("[ %d ] ", i+1)
}

// numberedLabel is one entry as it is drawn in a menu: its number, then its name.
// A nil node is the trailing navigation row, which is numbered like the rest.
func (a *App) numberedLabel(i int, n *node) string {
	name := a.navLabel()
	if n != nil {
		name = n.label(a.lang)
	}
	return a.numberTag(i) + name
}

// nodeLabel prefixes a menu entry with its icon, falling back to a bullet for
// entries that have no dedicated glyph. The navigation column uses it; the menus
// themselves are numbered.
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
	if a.system != nil {
		return strings.Join([]string{
			a.lang.T("hint_system"),
			a.lang.T("hint_back"),
			a.lang.T("hint_lang"),
			a.lang.T("hint_quit"),
		}, "  ")
	}
	hints := []string{a.lang.T("hint_navigate")}
	if a.menuColumns() > 1 {
		hints = append(hints, a.lang.T("hint_columns"))
	}
	return strings.Join(append(hints,
		a.lang.T("hint_enter"),
		a.lang.T("hint_back"),
		a.lang.T("hint_lang"),
		a.lang.T("hint_quit"),
	), "  ")
}
