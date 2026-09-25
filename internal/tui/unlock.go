package tui

import (
	"context"
	"fmt"
	"strings"
	"time"

	tea "charm.land/bubbletea/v2"

	"github.com/MinimaxFlora/EasySB/internal/i18n"
	"github.com/MinimaxFlora/EasySB/internal/icons"
	"github.com/MinimaxFlora/EasySB/internal/ui"
	"github.com/MinimaxFlora/EasySB/internal/unlock"
)

// buildUnlock is the 服务解锁状态 section: one entry that probes the whole catalogue and
// one page that probes a single service.
//
// The panel never probes by itself when the page is opened: a run makes up to three
// outbound requests per service and takes seconds, which is not something a navigation
// key should start. The section therefore reports what the last run found, and the
// entries start a new one.
func buildUnlock() *menu {
	return &menu{
		id:    "unlock",
		title: tk("unlock_title"),
		nodes: []*node{
			leaf("unlock-check", "unlock_check", "desc_unlock_check", unlockCheckAction(nil)),
			{id: "unlock-single", label: tk("unlock_single"), desc: tk("desc_unlock_single"), sub: buildUnlockSingle()},
		},
	}
}

// buildUnlockSingle lists every service in the catalogue, in the catalogue's own order,
// so a single service can be checked on its own when only one verdict is interesting.
func buildUnlockSingle() *menu {
	services := unlock.Catalogue()
	nodes := make([]*node, 0, len(services))
	for _, service := range services {
		service := service
		nodes = append(nodes, &node{
			id:     "unlock-" + service.ID,
			label:  func(l i18n.Lang) string { return unlockServiceName(l, service) },
			desc:   tk("desc_unlock_single"),
			action: unlockCheckAction([]string{service.ID}),
		})
	}
	return &menu{id: "unlock-single", title: tk("unlock_single"), nodes: nodes}
}

// unlockServiceName renders one service's display name. The catalogue carries the brand
// name (Netflix, ChatGPT), so the table is only consulted for the few services whose name
// is worth translating; a name the table does not know is shown as the catalogue wrote it.
func unlockServiceName(l i18n.Lang, service unlock.Service) string {
	key := "unlock_service_" + service.ID
	if name := l.T(key); name != key {
		return name
	}
	return service.Name
}

// unlockCheckAction probes the given services — the whole catalogue when ids is empty —
// and reports one line per verdict on the task screen, which is where a long run belongs:
// it shows lines as they arrive and keeps them readable afterwards. The report is handed
// back to the section, so the 看板 still shows it after the task screen is closed.
func unlockCheckAction(ids []string) actionFunc {
	return func(a *App) tea.Cmd {
		lang := a.lang
		icons := a.iconSet
		return a.startTask(lang.T("unlock_checking"), func(ctx context.Context, r *taskReporter) error {
			if len(ids) == 0 {
				r.Log(lang.Format("unlock_probing", len(unlock.Catalogue())))
			}
			report := unlock.New(unlock.Options{}).Report(ctx, ids...)
			for _, result := range report.Results {
				r.Log(unlockLine(lang, icons, result))
			}
			r.Log(unlockSummaryLine(lang, report))
			r.SetResult(report)
			return nil
		})
	}
}

// unlockLine words one verdict: the marker, the service, the verdict itself, the region
// the service disclosed, and — for anything that is not an unlocked service — why.
func unlockLine(lang i18n.Lang, ic icons.Set, result unlock.Result) string {
	mark := ic.Bullet
	switch result.Status {
	case unlock.StatusUnlocked:
		mark = ic.OK
	case unlock.StatusPartial:
		mark = ic.Warn
	case unlock.StatusBlocked:
		mark = ic.Err
	}
	line := fmt.Sprintf("%s %-26s %s", mark, unlockResultName(lang, result), lang.T("unlock_status_"+string(result.Status)))
	if result.Region != "" {
		line += "  " + lang.T("unlock_region") + " " + result.Region
	}
	if reason := unlockReasonText(lang, result); reason != "" {
		line += "  " + reason
	}
	return line
}

// unlockSummaryLine counts a finished run, which is the line an operator reads first.
func unlockSummaryLine(lang i18n.Lang, report unlock.Report) string {
	return fmt.Sprintf("%s: %s %d · %s %d · %s %d · %s %d · %s",
		lang.T("unlock_summary_label"), lang.T("unlock_status_"+string(unlock.StatusUnlocked)), report.Count(unlock.StatusUnlocked),
		lang.T("unlock_status_"+string(unlock.StatusPartial)), report.Count(unlock.StatusPartial),
		lang.T("unlock_status_"+string(unlock.StatusBlocked)), report.Count(unlock.StatusBlocked),
		lang.T("unlock_status_"+string(unlock.StatusFailed)), report.Count(unlock.StatusFailed),
		report.Elapsed.Round(time.Millisecond))
}

// unlockResultName is a result's display name: the catalogue name, translated when the
// table has a translation for it.
func unlockResultName(lang i18n.Lang, result unlock.Result) string {
	service, ok := unlock.Lookup(result.Service)
	if !ok {
		return result.Name
	}
	return unlockServiceName(lang, service)
}

// unlockReasonText explains a verdict the table can word. A probe that failed to reach a
// verdict carries the probe's own English text, which is more useful than a generic
// reason, so the translated reason and that text are both shown.
func unlockReasonText(lang i18n.Lang, result unlock.Result) string {
	if result.Status == unlock.StatusUnlocked {
		return ""
	}
	key := "unlock_reason_" + result.Reason
	reason := lang.T(key)
	if result.Text == "" {
		if reason == key {
			return ""
		}
		return reason
	}
	if reason == key {
		return result.Text
	}
	return reason + " · " + result.Text
}

// unlockBody is the section's 看板: what the last run found, or a note that none has run
// yet. It is drawn from the report the section kept, so the page never probes while it
// is being navigated.
func (a *App) unlockBody(w int) []string {
	s := a.style()
	inner := ui.InnerWidth(s, w)
	report := a.unlockReport
	last := a.lang.T("unlock_never")
	summary, summaryKind := a.lang.T("unlock_never_hint"), ui.KindPlain
	if report != nil && len(report.Results) > 0 {
		last = report.Started.Format("2006-01-02 15:04")
		summaryKind = ui.KindOK
		summary = fmt.Sprintf("%s %d · %s %d · %s %d · %s %d",
			a.lang.T("unlock_status_"+string(unlock.StatusUnlocked)), report.Count(unlock.StatusUnlocked),
			a.lang.T("unlock_status_"+string(unlock.StatusPartial)), report.Count(unlock.StatusPartial),
			a.lang.T("unlock_status_"+string(unlock.StatusBlocked)), report.Count(unlock.StatusBlocked),
			a.lang.T("unlock_status_"+string(unlock.StatusFailed)), report.Count(unlock.StatusFailed))
	}
	left := [][2]string{
		a.kv("unlock_last", last, ui.KindPlain),
		a.kv("unlock_summary_label", summary, summaryKind),
	}
	right := [][2]string{
		a.kv("unlock_scope", fmt.Sprintf("%d", len(unlock.Catalogue())), ui.KindPlain),
		a.kv("unlock_groups", unlockGroupNames(a.lang), ui.KindPlain),
	}
	return ui.TwoCol(s, left, right, inner)
}

// unlockGroupNames lists the catalogue's groups in the order the page walks them.
func unlockGroupNames(lang i18n.Lang) string {
	groups := unlock.Groups()
	names := make([]string, 0, len(groups))
	for _, group := range groups {
		names = append(names, lang.T("unlock_group_"+group))
	}
	return strings.Join(names, " · ")
}

// adoptTaskResult keeps what a finished task handed over. Only the unlock report is
// adopted today; the point is that the section's 看板 shows the run the operator just
// started instead of the previous one.
func (a *App) adoptTaskResult() {
	if a.task == nil {
		return
	}
	report, ok := a.task.taskResult().(unlock.Report)
	if !ok {
		return
	}
	a.unlockReport = &report
}
