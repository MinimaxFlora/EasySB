package tui

import (
	"fmt"
	"strings"
	"time"

	"github.com/MinimaxFlora/EasySB/internal/state"
	"github.com/MinimaxFlora/EasySB/internal/theme"
	"github.com/MinimaxFlora/EasySB/internal/ui"
)

// The dashboard is one frame of fixed size: a status strip on the first line, then
// the content of the current screen. Every screen is the same two boxes: the 看板 of
// the page the operator stands in on top, its entries below. On the main menu the
// 看板 is the wordmark and the panel's vitals and the entries are the main menu; inside
// a section the 看板 is that section's own reading and the entries are that page's
// menu. Only those two contents change as the operator moves, never the frame. The
// highlighted entry's explanation and the key hints follow the content instead of
// being pinned to the bottom, so a tall terminal shows one block at the top rather
// than two blocks with a gap between them.

// dashboard renders the current screen.
// bodyLayout is the fixed layout of the body area: the rows under the status strip and the
// blank line below it. Every screen that draws a box takes its slots from here, which is what
// keeps the boxes in the same rows on every page.
func (a *App) bodyLayout() layout {
	h := a.height
	if h <= 0 {
		h = 24
	}
	bodyH := h - 2
	if bodyH < 1 {
		bodyH = 1
	}
	return a.layoutFor(a.frameWidth(), bodyH)
}

func (a *App) dashboard() string {
	w := a.frameWidth()
	h := a.height
	if h <= 0 {
		h = 24
	}
	bodyH := h - 1
	if bodyH > 0 {
		bodyH--
	}
	lines := make([]string, 0, h)
	lines = append(lines, a.statusStrip(w))
	if h > 1 {
		lines = append(lines, "")
	}
	lines = append(lines, a.dashboardBody(w, bodyH)...)
	return ui.Fit(lines, w, h)
}

// contextLine is the explanation of the highlighted entry, and the font note on the
// system screen where there is no cursor to explain.
func (a *App) contextLine(w int) string {
	if a.system != nil {
		return a.style().Faint("· " + theme.Truncate(a.lang.T("font_check_hint"), maxInt(0, w-2)))
	}
	return a.itemDescription(w)
}

// tailLines is what follows the content on every screen: the explanation of the
// highlighted entry, then the key hints.
func (a *App) tailLines(w, h int) []string {
	out := []string{}
	if line := a.contextLine(w); line != "" && h >= 3 {
		out = append(out, line)
	}
	return append(out, a.dashboardHintLines(w, hintHeight(h-len(out)))...)
}

// hintHeight is how many lines the hints need: their own box when the screen has
// room for it, a single line when it does not.
func hintHeight(h int) int {
	switch {
	case h >= 22:
		return 3
	case h >= 6:
		return 1
	}
	return 0
}

// itemDescription is the one-line explanation of the highlighted entry, which the
// main menu prints under its own card and a section prints above the hints.
func (a *App) itemDescription(w int) string {
	if a.onNavRow() {
		return ""
	}
	n := a.selected()
	if n == nil || n.desc == nil {
		return ""
	}
	desc := n.desc(a.lang)
	if desc == "" {
		return ""
	}
	return a.style().Faint("· " + theme.Truncate(desc, maxInt(0, w-2)))
}

// dashboardBody fills the body of the frame below the status strip. Every page renders into
// the same slots: the section's 看板 in the top box, the entries of the page the operator
// stands in in the bottom one, and the same description line and key hints underneath. Only
// the contents change as the operator moves; the frame does not.
//
// Two screens are destinations rather than menus — the system screen and the panels that take
// over the body — and they keep the whole body, because their content is the page.
func (a *App) dashboardBody(w, h int) []string {
	if h <= 0 {
		return nil
	}
	if a.system != nil {
		tail := a.tailLines(w, h)
		return padLines(append(a.system.body(a, w, h-len(tail)), tail...), w, h)
	}
	l := a.layoutFor(w, h)
	tail := a.tailLinesPadded(w, h, l.tail)
	if a.sectionID() == "" {
		return padLines(append(a.rootSlots(w, l), tail...), w, h)
	}
	return padLines(append(a.sectionSlots(w, l), tail...), w, h)
}

// rootSlots is the main page in the panel's fixed layout: the welcome board on top, the root
// entries below, both in the rows every other page uses.
func (a *App) rootSlots(w int, l layout) []string {
	s := a.style()
	if !a.ready {
		return append(a.boxAt(a.lang.T("card_welcome"), []string{s.Faint(a.lang.T("loading") + "…")}, w, l.span()), blankRows(l.tail)...)
	}
	out := a.boxAt(a.lang.T("card_welcome"), a.rootCardBody(w, heroLevels), w, l.board)
	out = append(out, blankRows(l.gap)...)
	inner := ui.InnerWidth(s, w)
	root := a.stack[0]
	out = append(out, a.boxAt(root.title(a.lang), a.menuCells(root.nodes, a.index, inner), w, l.menu)...)
	return out
}

// sectionSlots is any page inside a section, in the same two slots: that section's 看板 above
// the entries of the page the operator is standing in. The 看板 keeps its rows even when a
// page has nothing to put in it, which is what stops the pages from moving under the cursor.
func (a *App) sectionSlots(w int, l layout) []string {
	out := make([]string, 0, l.span())
	title, rows := a.sectionPanel(w, boxRows(l.board))
	if title != "" {
		out = append(out, a.boxAt(title, rows, w, l.board)...)
		out = append(out, blankRows(l.gap)...)
	}
	menuTitle, menuRows := a.menuContentRows(w, l.menu)
	return append(out, a.boxAt(menuTitle, menuRows, w, l.menu)...)
}

// sectionPanel is the 看板 of the section the operator is inside: a section's own summary on
// the pages under it. limit is the rows it has to live in, which only the toolbox board uses —
// it is the one board whose content is a list of results rather than a few vitals.
func (a *App) sectionPanel(w int, limit int) (string, []string) {
	switch a.sectionID() {
	case "toolbox":
		return a.lang.T("panel_toolbox"), a.toolboxBody(w, limit)
	case "node":
		return a.lang.T("panel_node"), a.nodeBody(w)
	case "domain":
		return a.lang.T("panel_domain"), a.domainBody(w)
	case "subscribe":
		return a.lang.T("panel_subscribe"), a.subscribeBody(w)
	case "users":
		return a.lang.T("panel_accounts"), a.accountsBody(w)
	case "service":
		return a.lang.T("panel_service"), a.serviceBody(w)
	case "bbr":
		return a.lang.T("panel_bbr"), a.bbrBody(w)
	case "script-update":
		return a.lang.T("panel_update"), a.updateBody(w)
	case "uninstall":
		return a.lang.T("panel_uninstall"), a.selfBody(w)
	}
	return a.lang.T("panel_overview"), a.overviewBody(w)
}

// menuContentRows is the bottom box's content for the page the operator stands in: its entries
// laid out in the panel's columns, with the row that leads back out laid out as one more
// entry. Every menu is drawn the same way — the main menu and the pages under it — which is
// what makes the box the same size on every page.
func (a *App) menuContentRows(w int, height int) (string, []string) {
	inner := ui.InnerWidth(a.style(), w)
	nodes := a.current().nodes
	if a.hasNavRow() {
		cells := make([]*node, 0, len(nodes)+1)
		cells = append(cells, nodes...)
		// A nil node is the way back out: menuCells renders it from the navigation label,
		// which is the same row the one-column layout used to append.
		cells = append(cells, nil)
		return a.current().title(a.lang), a.menuCells(cells, a.index, inner)
	}
	return a.current().title(a.lang), a.menuCells(nodes, a.index, inner)
}

// sectionMenuRows is the height the entries box is never squeezed below: three
// entries and the row that leads back out of the section.

// domainBody is the domain section's 看板: the name in use and what is deployed
// behind it, which is what its certificate actions act on.
func (a *App) domainBody(w int) []string {
	s := a.style()
	st := a.status
	inner := ui.InnerWidth(s, w)
	nodeText, nodeKind := a.nodeState()
	service, svcKind := a.serviceState()
	left := [][2]string{
		a.kv("status_domain", a.panelValue(st.Domain), ui.KindPlain),
		a.kv("status_node", nodeText, nodeKind),
	}
	right := [][2]string{
		a.kv("status_service", service, svcKind),
		a.kv("status_ports", a.panelValue(enabledPorts(st.Ports)), ui.KindPlain),
	}
	return ui.TwoCol(s, left, right, inner)
}

// subscribeBody is the subscription section's 看板: where subscriptions are served,
// how often usage is read, and how many accounts they carry.
func (a *App) subscribeBody(w int) []string {
	s := a.style()
	st := a.status
	inner := ui.InnerWidth(s, w)
	left := [][2]string{
		a.kv("status_sub", a.subscriptionSummary(), ui.KindPlain),
		a.kv("param_sub_sync", a.syncIntervalText(), ui.KindPlain),
	}
	right := [][2]string{
		a.kv("users_summary_total", fmt.Sprintf("%d", len(a.accounts)), ui.KindPlain),
		a.kv("status_domain", a.panelValue(st.Domain), ui.KindPlain),
	}
	return ui.TwoCol(s, left, right, inner)
}

// serviceBody is the service section's 看板: the three things its actions change —
// whether the service runs, whether it starts at boot, and on which ports.
func (a *App) serviceBody(w int) []string {
	s := a.style()
	st := a.status
	inner := ui.InnerWidth(s, w)
	service, svcKind := a.serviceState()
	autostart, autoKind := a.autostartState()
	left := [][2]string{
		a.kv("status_service", service, svcKind),
		a.kv("status_autostart", autostart, autoKind),
	}
	right := [][2]string{
		a.kv("status_ports", a.panelValue(enabledPorts(st.Ports)), ui.KindPlain),
		a.kv("device_uptime", withFallback(humanDuration(st.Uptime), "—"), ui.KindPlain),
	}
	return ui.TwoCol(s, left, right, inner)
}

// bbrBody is the BBR section's 看板: whether acceleration is on, which kernel runs it
// and how many BBR kernels are installed. Acceleration is the congestion control the
// kernel is actually using, not the kernel release; the local reading is taken when
// the section is entered, and before it lands the rows say so instead of guessing.
func (a *App) bbrBody(w int) []string {
	s := a.style()
	inner := ui.InnerWidth(s, w)
	st := a.bbrStatus
	if st.Running == "" {
		notRead := a.lang.T("not_read")
		left := [][2]string{
			a.kv("bbr_state", notRead, ui.KindPlain),
			a.kv("bbr_congestion", notRead, ui.KindPlain),
		}
		right := [][2]string{
			a.kv("bbr_running_kernel", notRead, ui.KindPlain),
			a.kv("bbr_row_installed", notRead, ui.KindPlain),
		}
		return ui.TwoCol(s, left, right, inner)
	}
	accel, accelKind := a.lang.T("state_disabled"), ui.KindPlain
	if st.Congestion == "bbr" {
		accel, accelKind = a.lang.T("bbr_on"), ui.KindOK
	}
	left := [][2]string{
		a.kv("bbr_state", accel, accelKind),
		a.kv("bbr_congestion", a.panelValue(st.Congestion), ui.KindPlain),
	}
	right := [][2]string{
		a.kv("bbr_running_kernel", a.panelValue(st.Running), ui.KindPlain),
		a.kv("bbr_row_installed", fmt.Sprintf("%d", len(st.Kernels)), ui.KindPlain),
	}
	rows := ui.TwoCol(s, left, right, inner)
	if st.NeedsReboot() {
		// The installed kernel only becomes the running one after a reboot, which is
		// the one thing the operator has to act on after an install.
		rows = append(rows, "", s.Faint("  ")+s.Colored(s.Warn, a.iconSet.Warn+" "+a.lang.T("bbr_reboot_pending")))
	}
	return rows
}

// updateBody is the version section's 看板: what the panel and the core are on.
func (a *App) updateBody(w int) []string {
	s := a.style()
	inner := ui.InnerWidth(s, w)
	coreText, coreKind := a.coreSummary()
	left := [][2]string{
		a.kv("status_version", a.scriptVersion, ui.KindOK),
	}
	right := [][2]string{
		a.kv("status_core", coreText, coreKind),
	}
	return ui.TwoCol(s, left, right, inner)
}

// selfBody is the uninstall section's 看板: what the script installed, which is what
// removing it takes away.
func (a *App) selfBody(w int) []string {
	s := a.style()
	inner := ui.InnerWidth(s, w)
	service, svcKind := a.serviceState()
	nodeText, nodeKind := a.nodeState()
	left := [][2]string{
		a.kv("status_version", a.scriptVersion, ui.KindOK),
		a.kv("status_service", service, svcKind),
	}
	right := [][2]string{
		a.kv("status_node", nodeText, nodeKind),
		a.kv("users_summary_total", fmt.Sprintf("%d", len(a.accounts)), ui.KindPlain),
	}
	return ui.TwoCol(s, left, right, inner)
}

// nodeBody lists the node parameters exactly as the config stores them.
func (a *App) nodeBody(w int) []string {
	s := a.style()
	cfg := state.Load()
	inner := ui.InnerWidth(s, w)
	left := [][2]string{
		a.kv("param_sub_port", fmt.Sprint(cfg.SubPort()), ui.KindPlain),
		a.kv("param_sub_sync", cfg.SyncInterval().String(), ui.KindPlain),
		a.kv("param_hop", a.panelValue(cfg.HopRange), ui.KindPlain),
	}
	right := [][2]string{
		a.kv("param_ports", a.panelValue(portSummary(cfg)), ui.KindPlain),
		a.kv("param_sni", a.panelValue(cfg.RealitySNI), ui.KindPlain),
		a.kv("node_shortid", a.panelValue(cfg.RealitySID), ui.KindPlain),
	}
	return ui.TwoCol(s, left, right, inner)
}

// heroLevels is how many shapes the wordmark block has, from the full wordmark,
// tagline and quote down to nothing at all.
const heroLevels = 3

// rootCard is the main menu's 看板: the wordmark, the tagline and the quote, a rule,
// then the service, node and version rows.
func (a *App) rootCard(w, level int) []string {
	s := a.style()
	return ui.Card(s, a.lang.T("card_welcome"), "", a.rootCardBody(w, level), w)
}

// rootCardBody is the welcome board's content without its frame. The layout measures this to
// learn how many rows the top box has, and the main page draws the very same rows in the slot
// that measurement came from.
func (a *App) rootCardBody(w, level int) []string {
	s := a.style()
	body := []string{}
	if level > 0 && w >= 46 && !s.Met.Compact {
		body = append(body, a.heroBody(w, level)...)
		body = append(body, ui.Rule(s, ui.InnerWidth(s, w)))
	}
	body = append(body, a.overviewBody(w)...)
	return body
}

// menuCellRows lays the main menu's entries out in two columns; the left column
// takes the extra row when the count is odd. Below two usable columns the entries
// fall back to one per row, so no entry can be cut in half.

// menuCells lays the entries of any menu into the panel's columns: two of them once the frame
// is wide enough for the descriptions to survive, one otherwise. It takes the nodes and the
// cursor rather than reading the current page, because the layout measures the main menu's box
// while the operator may be standing on another page.
func (a *App) menuCells(nodes []*node, cursor int, inner int) []string {
	n := len(nodes)
	if n == 0 {
		return nil
	}
	colW := (inner - 1) / 2
	if colW < 16 {
		rows := make([]string, 0, n)
		for i, nd := range nodes {
			rows = append(rows, a.menuCell(i == cursor, i, nd, inner))
		}
		return rows
	}
	half := (n + 1) / 2
	rows := make([]string, 0, half)
	for i := 0; i < half; i++ {
		row := a.menuCell(i == cursor, i, nodes[i], colW)
		if j := i + half; j < n {
			row += " " + a.menuCell(j == cursor, j, nodes[j], inner-colW-1)
		} else {
			row += strings.Repeat(" ", inner-colW)
		}
		rows = append(rows, row)
	}
	return rows
}

// menuCell renders one entry inside a column: its number and label, and the description
// beside them whenever the column is wide enough to hold both. The description is what tells
// an operator what an entry does, so it stays with the entry rather than moving to a line of
// its own — which is what lets every page use the same two-column box the main menu uses.
func (a *App) menuCell(selected bool, i int, n *node, cellW int) string {
	descCol := a.menuDescColumn(cellW, a.menuLabelColumn())
	return a.menuRow(selected, i, n, cellW, descCol, cellW)
}

// heroBody is the wordmark block shown at the top of a tall main menu: the block
// letters, the tagline and the quote. Its level is how much of that the screen can
// afford, so a medium terminal keeps the wordmark and drops the quote rather than
// losing all three at once.
func (a *App) heroBody(w, level int) []string {
	inner := ui.InnerWidth(a.style(), w)
	lines := a.logoLines(inner)
	if level >= 2 {
		lines = append(lines, a.taglineLine(inner))
	}
	if level >= 3 && a.quote != "" {
		lines = append(lines, a.quoteLine(inner))
	}
	return lines
}

// statusStrip is the one-line summary that stays on every screen.
func (a *App) statusStrip(w int) string {
	s := a.style()
	if !a.ready {
		return s.Faint(a.lang.T("loading") + "…")
	}
	st := a.status
	items := []ui.StripItem{
		{Icon: a.iconSet.Host, Label: st.Hostname},
	}
	svcText, svcKind := a.serviceState()
	nodeText, nodeKind := a.nodeState()
	items = append(items,
		ui.StripItem{Icon: a.iconSet.Service, Label: a.lang.T("status_service"), Value: svcText, Kind: svcKind},
		ui.StripItem{Icon: a.iconSet.Rocket, Label: a.lang.T("status_node"), Value: nodeText, Kind: nodeKind},
	)
	if st.CoreVersion == "" {
		items = append(items, ui.StripItem{Icon: a.iconSet.Core, Label: a.lang.T("status_core"), Value: a.lang.T("state_unknown")})
	} else {
		items = append(items, ui.StripItem{Icon: a.iconSet.Core, Label: a.lang.T("status_core"), Value: st.CoreVersion, Kind: ui.KindOK})
	}
	if st.MemTotal > 0 {
		used := st.MemTotal - minU64(st.MemAvail, st.MemTotal)
		items = append(items, ui.StripItem{Icon: "", Label: a.lang.T("device_memory"),
			Value: fmt.Sprintf("%d%%", used*100/st.MemTotal), Kind: loadKind(float64(used) / float64(st.MemTotal))})
	}
	if st.DiskTotal > 0 {
		free := minU64(st.DiskFree, st.DiskTotal)
		items = append(items, ui.StripItem{Icon: "", Label: a.lang.T("device_disk"),
			Value: fmt.Sprintf("%d%%", (st.DiskTotal-free)*100/st.DiskTotal),
			Kind:  loadKind(float64(st.DiskTotal-free) / float64(st.DiskTotal))})
	}
	if st.LoadAvg != "" {
		items = append(items, ui.StripItem{Icon: "", Label: a.lang.T("device_load"), Value: st.LoadAvg})
	}
	return ui.Strip(s, items, w)
}

// coreSummary words the core the panel carries as "version · counters", where the
// counters half says whether per-account traffic can be measured at all. It is the same
// answer in the wordmark card, the 看板 and the system card, so it is worded once here.
func (a *App) coreSummary() (string, ui.Kind) {
	if a.status.CoreVersion == "" {
		return a.lang.T("state_unknown"), ui.KindPlain
	}
	return a.status.CoreVersion + " · " + a.coreStatsLabel(), ui.KindOK
}

// coreStatsLabel says whether this build counts per-account traffic. The answer comes
// from the build tags the binary was compiled with, so it cannot drift from what the
// core actually does.
func (a *App) coreStatsLabel() string {
	if a.status.StatsCapable {
		return a.lang.T("core_stats_on")
	}
	return a.lang.T("core_stats_off")
}

// overviewBody is the service/node/version card.
func (a *App) overviewBody(w int) []string {
	s := a.style()
	st := a.status
	inner := ui.InnerWidth(s, w)
	svcText, svcKind := a.serviceState()
	nodeText, nodeKind := a.nodeState()
	coreText, coreKind := a.coreSummary()
	autostart, autoKind := a.autostartState()
	left := [][2]string{
		a.kv("ov_service", svcText, svcKind),
		a.kv("ov_node", nodeText, nodeKind),
		a.kv("status_autostart", autostart, autoKind),
		a.kv("status_ports", a.panelValue(enabledPorts(st.Ports)), ui.KindPlain),
	}
	right := [][2]string{
		a.kv("ov_version", a.scriptVersion, ui.KindOK),
		a.kv("ov_core", coreText, coreKind),
		a.kv("status_domain", a.panelValue(st.Domain), ui.KindPlain),
		a.kv("status_sub", a.subscriptionSummary(), ui.KindPlain),
	}
	return ui.TwoCol(s, left, right, inner)
}

// subscriptionSummary describes where subscriptions are served and how often the
// traffic counters are pushed.
func (a *App) subscriptionSummary() string {
	st := a.status
	if st.SubPort == 0 {
		return a.lang.T("not_set")
	}
	return fmt.Sprintf(":%d · %ds", st.SubPort, st.SubSyncSecs)
}

// syncIntervalText is the accounting interval on its own, which reads as "not set"
// rather than "0s" while no node is deployed.
func (a *App) syncIntervalText() string {
	if a.status.SubSyncSecs <= 0 {
		return a.lang.T("not_set")
	}
	return fmt.Sprintf("%ds", a.status.SubSyncSecs)
}

// accountsBody summarises the accounts: how many, how many still work, and how
// much traffic they have used.
func (a *App) accountsBody(w int) []string {
	s := a.style()
	inner := ui.InnerWidth(s, w)
	now := time.Now()
	active, disabled, limited := 0, 0, 0
	var traffic int64
	for _, u := range a.accounts {
		switch statusKey(u.Status(now)) {
		case "user_status_active":
			active++
		case "user_status_disabled":
			disabled++
		default:
			limited++
		}
		traffic += int64(u.UploadBytes + u.DownloadBytes)
	}
	left := [][2]string{
		a.kv("users_summary_total", fmt.Sprintf("%d", len(a.accounts)), ui.KindPlain),
		a.kv("users_summary_active", fmt.Sprintf("%d", active), activeKind(active, len(a.accounts))),
	}
	right := [][2]string{
		a.kv("users_summary_limited", fmt.Sprintf("%d", limited+disabled), limitedKind(limited, disabled)),
		a.kv("users_summary_traffic", formatSize(traffic), ui.KindPlain),
	}
	return ui.TwoCol(s, left, right, inner)
}

// state words a state with its glyph, so the same state always looks the same in
// the status strip and in the overview card.
func (a *App) state(key, glyph string) string { return glyph + " " + a.lang.T(key) }

// serviceState describes the kernel service.
func (a *App) serviceState() (string, ui.Kind) {
	switch a.status.Service {
	case "running":
		return a.state("state_running", a.iconSet.Running), ui.KindOK
	case "stopped":
		return a.state("state_stopped", a.iconSet.Stopped), ui.KindWarn
	default:
		return a.state("state_unknown", a.iconSet.Stopped), ui.KindPlain
	}
}

// nodeState describes whether a node is deployed.
func (a *App) nodeState() (string, ui.Kind) {
	if a.status.Deployed {
		return a.state("node_deployed", a.iconSet.Enabled), ui.KindOK
	}
	return a.state("node_not_deployed", a.iconSet.Stopped), ui.KindWarn
}

// autostartState describes the boot unit.
func (a *App) autostartState() (string, ui.Kind) {
	switch a.status.Autostart {
	case "enabled":
		return a.state("state_enabled", a.iconSet.Enabled), ui.KindOK
	case "disabled":
		return a.state("state_disabled", a.iconSet.Disabled), ui.KindPlain
	default:
		return a.state("state_unknown", a.iconSet.Stopped), ui.KindPlain
	}
}

// kv builds one labelled, tone-coloured value row.
func (a *App) kv(labelKey, value string, k ui.Kind) [2]string {
	return [2]string{a.lang.T(labelKey), a.style().Bold(k.Color(a.style()), value)}
}

// dashboardHintLines returns the pinned hints: the three-line box when the
// terminal can spare the rows, a single line otherwise.
func (a *App) dashboardHintLines(w, hintH int) []string {
	if hintH <= 0 {
		return nil
	}
	hint := a.dashboardHint()
	if a.toast != "" {
		hint = a.renderToast(w - 4)
	}
	if hintH == 3 {
		return a.hintBox(hint, w)
	}
	return []string{a.hintLine(hint, w)}
}

// loadKind flags a resource that is running out.
func loadKind(ratio float64) ui.Kind {
	switch {
	case ratio >= 0.95:
		return ui.KindErr
	case ratio >= 0.85:
		return ui.KindWarn
	default:
		return ui.KindPlain
	}
}

func activeKind(active, total int) ui.Kind {
	if total == 0 || active == 0 {
		return ui.KindWarn
	}
	return ui.KindOK
}

func limitedKind(limited, disabled int) ui.Kind {
	if limited+disabled > 0 {
		return ui.KindWarn
	}
	return ui.KindPlain
}

func withFallback(value, fallback string) string {
	if strings.TrimSpace(value) == "" {
		return fallback
	}
	return value
}

func minU64(a, b uint64) uint64 {
	if a < b {
		return a
	}
	return b
}
