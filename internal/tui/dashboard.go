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
// the content of the current screen — the wordmark, the panel's vitals and the menu
// on the main menu; the navigation column beside the section's own panel inside a
// section. The highlighted entry's explanation and the key hints follow the content
// instead of being pinned to the bottom, so a tall terminal shows one block at the
// top rather than two blocks with a gap between them.

// navMinWidth is where the two-column layout starts. Below it the navigation is
// dropped and the content column takes the whole width, because a 14-column
// navigation shows nothing useful.
const navMinWidth = 76

// dashboard renders the current screen.
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

// dashboardBody hands the main menu the whole width: its entries are a two-column
// card of their own, so the page needs no navigation column. Inside a section the
// column comes back, because that is where cross-section movement happens. The
// system screen also takes the whole width: it is a destination, not a menu.
func (a *App) dashboardBody(w, h int) []string {
	if h <= 0 {
		return nil
	}
	if a.system != nil {
		tail := a.tailLines(w, h)
		return padLines(append(a.system.body(a, w, h-len(tail)), tail...), w, h)
	}
	if a.sectionID() == "" {
		tail := a.tailLines(w, h)
		return padLines(append(a.rootCards(w, h-len(tail)), tail...), w, h)
	}
	s := a.style()
	navW := 0
	if w >= navMinWidth {
		navW = s.Met.NavWidth
		if navW <= 0 {
			navW = 24
		}
		if max := w / 3; navW > max {
			navW = max
		}
		if navW < 16 {
			navW = 16
		}
	}
	gutter := 0
	if navW > 0 {
		gutter = s.Met.Gutter
		if gutter < 1 {
			gutter = 1
		}
	}
	contentW := w - navW - gutter
	if contentW < 20 {
		navW, gutter, contentW = 0, 0, w
	}

	var left []string
	if navW > 0 {
		left = a.navColumn(navW, h)
	}
	// The hints belong to the content column: the navigation keeps its full
	// height beside them.
	right := a.sectionContent(contentW, h, navW > 0)

	out := make([]string, 0, h)
	for i := 0; i < h; i++ {
		row := ""
		if i < len(left) {
			row = theme.Pad(left[i], navW)
		} else if navW > 0 {
			row = strings.Repeat(" ", navW)
		}
		if gutter > 0 {
			row += strings.Repeat(" ", gutter)
		}
		if i < len(right) {
			row += theme.Pad(right[i], contentW)
		} else {
			row += strings.Repeat(" ", contentW)
		}
		out = append(out, row)
	}
	return out
}

// sectionContent renders one section as a single card: the section's own panel on
// top, a rule, then its entries, and the hints under the card. The section name is
// not part of the card — the navigation column already marks it, unless the
// navigation is hidden on a narrow terminal, where a breadcrumb takes its place.
func (a *App) sectionContent(w, h int, withNav bool) []string {
	s := a.style()
	inner := ui.InnerWidth(s, w)
	title, rows := a.sectionPanel(w)
	body := make([]string, 0, len(rows)+6)
	if len(rows) > 0 {
		body = append(body, rows...)
		body = append(body, ui.Rule(s, inner))
	} else if !withNav {
		// No panel and no navigation column: the breadcrumb is the only thing
		// that says which section this is.
		body = append(body, s.Faint(theme.Truncate(a.breadcrumb(), inner)), "")
	}

	tail := a.tailLines(w, h)
	limit := h - len(tail) - 2 - len(body)
	if limit < 1 {
		limit = 1
	}
	descCol := a.menuDescColumn(inner, a.menuLabelColumn())
	cursorWidth := a.menuCursorWidth(inner)
	items, hidden := a.menuViewport(limit, inner, descCol, cursorWidth)
	body = append(body, items...)
	if hidden > 0 {
		body = append(body, s.Faint(fmt.Sprintf("  +%d", hidden)))
	}
	if a.hasNavRow() {
		body = append(body, a.rowLine(a.onNavRow(), a.numberedLabel(len(a.current().nodes), nil), inner, cursorWidth))
	}
	out := ui.Card(s, title, "", body, w)
	return append(out, tail...)
}

// sectionPanel is the panel that describes what the operator is about to change,
// returned as a title and the rows to draw under it so the entries can share its
// card. Only the node section has one for now: its parameters are the ones an
// operator reads while changing them.
func (a *App) sectionPanel(w int) (string, []string) {
	if a.sectionID() != "node" {
		return "", nil
	}
	return a.lang.T("panel_node"), a.nodeBody(w)
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

// rootCards draws the main menu as one frame: the wordmark and the panel's vitals on
// top, a rule, then the entries under a labelled rule. The section pages have the
// same shape — panel above, entries below, one frame — so the panel reads the same
// at every level. The result is not padded to its height, so whatever follows the
// menu stays right under it, and the menu is never traded away: every entry stays
// reachable on a short terminal.
func (a *App) rootCards(w, h int) []string {
	s := a.style()
	if !a.ready {
		return ui.Card(s, a.lang.T("card_welcome"), "", []string{s.Faint(a.lang.T("loading") + "…")}, w)
	}
	card := a.rootCard(w, heroLevels)
	for level := heroLevels; level >= 0 && len(card) > h; level-- {
		card = a.rootCard(w, level)
	}
	if len(card) <= h {
		return card
	}
	// Even without its wordmark the panel does not fit: the entries are what the
	// screen is for, so they get a card of their own and the vitals give up their
	// slot. A tiny terminal then still gets a frame instead of an empty column.
	menu := a.rootMenuLines(w)
	if len(menu) > h {
		return menu[:maxInt(0, h)]
	}
	return menu
}

// heroLevels is how many shapes the wordmark block has, from the full wordmark,
// tagline and quote down to nothing at all.
const heroLevels = 3

// rootCard is the main menu as a single frame: the wordmark, the panel's vitals, then
// the entries, divided by rules rather than by borders. The entry block keeps its own
// label on the rule above it, so the menu is still named without a second card.
func (a *App) rootCard(w, level int) []string {
	s := a.style()
	inner := ui.InnerWidth(s, w)
	body := []string{}
	if level > 0 && w >= 46 && !s.Met.Compact {
		body = append(body, a.heroBody(w, level)...)
		body = append(body, ui.Rule(s, inner))
	}
	body = append(body, a.overviewBody(w)...)
	body = append(body, ui.RuleLabel(s, a.current().title(a.lang), inner))
	body = append(body, a.menuCellRows(inner)...)
	return ui.Card(s, a.lang.T("card_welcome"), "", body, w)
}

// rootMenuLines renders the main menu on its own, for terminals too short to hold
// the panel's vitals above it.
func (a *App) rootMenuLines(w int) []string {
	s := a.style()
	inner := ui.InnerWidth(s, w)
	return ui.Card(s, a.current().title(a.lang), "", a.menuCellRows(inner), w)
}

// menuCellRows lays the main menu's entries out in two columns; the left column
// takes the extra row when the count is odd. Below two usable columns the entries
// fall back to one per row, so no entry can be cut in half.
func (a *App) menuCellRows(inner int) []string {
	nodes := a.current().nodes
	n := len(nodes)
	if n == 0 {
		return nil
	}
	colW := (inner - 1) / 2
	if colW < 16 {
		rows := make([]string, 0, n)
		for i, nd := range nodes {
			rows = append(rows, a.menuCell(i == a.index, i, nd, inner))
		}
		return rows
	}
	half := (n + 1) / 2
	rows := make([]string, 0, half)
	for i := 0; i < half; i++ {
		row := a.menuCell(i == a.index, i, nodes[i], colW)
		if j := i + half; j < n {
			row += " " + a.menuCell(j == a.index, j, nodes[j], inner-colW-1)
		} else {
			row += strings.Repeat(" ", inner-colW)
		}
		rows = append(rows, row)
	}
	return rows
}

// menuCell renders one entry of the two-column menu: its number and label, filled
// out to the column so the selection bar keeps one size while the cursor moves.
func (a *App) menuCell(selected bool, i int, n *node, cellW int) string {
	marker := "  "
	if selected {
		marker = "▌ "
	}
	line := theme.Pad(" "+marker+theme.Truncate(a.numberedLabel(i, n), maxInt(0, cellW-3)), cellW)
	if selected {
		return a.palette.SelectedRow(line)
	}
	return a.palette.Bold(a.palette.Text, line)
}

// breadcrumb is the root-to-current path, which is what makes the two-column
// layout readable when the navigation column is not there to say where you are.
func (a *App) breadcrumb() string {
	parts := make([]string, 0, len(a.stack))
	for _, m := range a.stack {
		parts = append(parts, m.title(a.lang))
	}
	return strings.Join(parts, " › ")
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
		items = append(items, ui.StripItem{Icon: a.iconSet.Core, Label: a.lang.T("status_core"), Value: a.lang.T("ver_not_installed")})
	} else {
		kind := ui.KindOK
		if st.CoreChannel == "alpha" {
			kind = ui.KindWarn
		}
		items = append(items, ui.StripItem{Icon: a.iconSet.Core, Label: a.lang.T("status_core"), Value: st.CoreVersion, Kind: kind})
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

// overviewBody is the service/node/version card.
func (a *App) overviewBody(w int) []string {
	s := a.style()
	st := a.status
	inner := ui.InnerWidth(s, w)
	svcText, svcKind := a.serviceState()
	nodeText, nodeKind := a.nodeState()
	coreText, coreKind := a.lang.T("ver_not_installed"), ui.KindPlain
	if st.CoreVersion != "" {
		coreText, coreKind = st.CoreVersion+" ["+a.lang.T(channelTagKey(st.CoreChannel))+"]", ui.KindOK
		if st.CoreChannel == "alpha" {
			coreKind = ui.KindWarn
		}
	}
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

// deviceBody is the host card: meters for the three resources that run out, then
// the identity of the machine.
func (a *App) deviceBody(w int) []string {
	s := a.style()
	st := a.status
	inner := ui.InnerWidth(s, w)
	var body []string
	meter := func(labelKey string, total, free uint64) {
		if total == 0 {
			return
		}
		free = minU64(free, total)
		used := total - free
		body = append(body, ui.MeterLine(s, a.lang.T(labelKey), usageCell(total, free),
			float64(used)/float64(total), inner))
	}
	meter("device_memory", st.MemTotal, st.MemAvail)
	meter("device_disk", st.DiskTotal, st.DiskFree)
	meter("device_swap", st.SwapTotal, st.SwapFree)
	if len(body) > 0 {
		body = append(body, "")
	}
	left := [][2]string{
		a.kv("device_host", st.Hostname, ui.KindPlain),
		a.kv("device_os", withFallback(st.OS, a.lang.T("state_unknown")), ui.KindPlain),
		a.kv("device_kernel", withFallback(st.Kernel, a.lang.T("state_unknown")), ui.KindPlain),
		a.kv("device_cpu", a.cpuSummary(), ui.KindPlain),
	}
	right := [][2]string{
		a.kv("device_uptime", withFallback(humanDuration(st.Uptime), "—"), ui.KindPlain),
		a.kv("device_load", withFallback(st.LoadAvg, "—"), ui.KindPlain),
		a.kv("device_local_ipv4", withFallback(st.LocalIPv4, "—"), ui.KindPlain),
		a.kv("device_local_ipv6", withFallback(st.LocalIPv6, "—"), ui.KindPlain),
	}
	return append(body, ui.TwoCol(s, left, right, inner)...)
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
