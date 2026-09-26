package tui

import (
	"context"
	"strings"
	"time"

	tea "charm.land/bubbletea/v2"
	"charm.land/lipgloss/v2"

	"github.com/MinimaxFlora/EasySB/internal/i18n"
	"github.com/MinimaxFlora/EasySB/internal/toolbox"
	"github.com/MinimaxFlora/EasySB/internal/toolbox/tools"
	"github.com/MinimaxFlora/EasySB/internal/ui"
)

// toolOutcome is one finished run of a toolbox entry: what it reported, whether it could run
// at all, and when. The section keeps the last outcome per tool, which is what its 看板
// shows and what the report screen draws.
type toolOutcome struct {
	id     string
	result toolbox.Result
	err    error
	when   time.Time
}

// buildToolbox is the 工具箱 section: one page per group and one entry per tool, with a
// report screen the entries share.
//
// The panel never runs a tool on its own when the section is opened: a speed test, a disk
// benchmark or a traceroute is not something a navigation key should start. The board
// therefore reports what the last run found, and the entries start a new one.
func buildToolbox() *menu {
	nodes := make([]*node, 0, len(tools.Groups()))
	for _, group := range tools.Groups() {
		nodes = append(nodes, &node{
			id:    "toolbox-" + group,
			label: tk("toolbox_group_" + group),
			desc:  tk("desc_toolbox_group_" + group),
			sub:   buildToolGroup(group),
		})
	}
	return &menu{id: "toolbox", title: tk("toolbox_title"), nodes: nodes}
}

// buildToolGroup lists one group's entries in registry order, so the menu and the board
// cannot disagree about what the toolbox holds.
func buildToolGroup(group string) *menu {
	entries := tools.InGroup(group)
	nodes := make([]*node, 0, len(entries))
	for _, tool := range entries {
		tool := tool
		nodes = append(nodes, leaf("tool-"+tool.ID, "toolbox_"+tool.ID, "desc_toolbox_"+tool.ID, toolAction(tool.ID)))
	}
	return &menu{id: "toolbox-" + group, title: tk("toolbox_group_" + group), nodes: nodes}
}

// toolAction runs one tool on the task screen and hands the outcome to the report screen.
// The task screen carries the progress a slow tool prints (a benchmark's throughput, a
// traceroute's hops); the report carries the table.
func toolAction(id string) actionFunc {
	return func(a *App) tea.Cmd {
		tool, ok := tools.Lookup(id)
		if !ok {
			return nil
		}
		title := a.lang.T("toolbox_" + id)
		return a.startTask(title, func(ctx context.Context, r *taskReporter) error {
			result, err := tool.Run(ctx, toolbox.Options{Log: r.Log})
			r.SetResult(toolOutcome{id: id, result: result, err: err, when: time.Now()})
			if err != nil {
				return err
			}
			if result.Summary != "" {
				r.Log(result.Summary)
			}
			return nil
		})
	}
}

// adoptTaskResult keeps what a finished task handed over. The report screen draws it as
// soon as the task screen is dismissed, so a run ends on its table rather than on its log.
func (a *App) adoptTaskResult() {
	if a.task == nil {
		return
	}
	outcome, ok := a.task.taskResult().(toolOutcome)
	if !ok {
		return
	}
	if a.toolResults == nil {
		a.toolResults = make(map[string]toolOutcome)
	}
	a.toolResults[outcome.id] = outcome
	a.report = &outcome
	a.saveBoard()
	// The result replaces the running screen as soon as the run ends: the task screen has
	// said everything it has to say by then, and making the operator press a key to see a
	// measurement they asked for is a step with nothing in it.
	a.task = nil
}

// rerunReport starts the reported tool again, which is the one thing an operator wants
// after reading a table with a bad number in it.
func (a *App) rerunReport() tea.Cmd {
	if a.report == nil {
		return nil
	}
	id := a.report.id
	a.report = nil
	return toolAction(id)(a)
}

// reportScreen draws one tool's report: the title of the run, its table, and the notes
// underneath. A failed run says so before the table, because a table of zeros that came
// from a permission error would otherwise read as a measurement.
func (a *App) reportScreen() string {
	w, h := a.frameWidth(), a.height
	if h <= 0 {
		h = 24
	}
	s := a.style()
	inner := ui.InnerWidth(s, w)
	outcome := a.report
	if outcome == nil {
		return framePanel(a.palette, a.lang, w, h, nil, a.lang.T("esc_back"))
	}

	body := make([]string, 0, len(outcome.result.Rows)+8)
	if outcome.err != nil {
		for _, line := range wrapText(outcome.err.Error(), inner) {
			body = append(body, s.Colored(s.Err, line))
		}
	}
	headers, rows := a.reportTable(*outcome)
	body = append(body, ui.Table(s, headers, rows, inner)...)
	if len(outcome.result.Notes) > 0 {
		body = append(body, "")
		for _, note := range outcome.result.Notes {
			for i, line := range wrapText("· "+a.localizeText(note), inner) {
				if i == 0 {
					body = append(body, s.Faint(line))
					continue
				}
				body = append(body, s.Faint("  "+strings.TrimLeft(line, "· ")))
			}
		}
	}
	if outcome.result.Summary != "" {
		body = append(body, "", s.Bold(s.OK, a.localizeText(outcome.result.Summary)))
	}
	body = append(body, "", s.Faint(a.lang.T("toolbox_ran_at")+" "+outcome.when.Format("2006-01-02 15:04:05")))

	hint := a.lang.T("toolbox_rerun") + "  " + a.lang.T("hint_back")
	return framePanel(a.palette, a.lang, w, h, body, a.palette.Dim(hint))
}

// localizeText words the verdict tokens inside a sentence a tool built out of them, such as
// a summary or a note. A tool that never uses those tokens is passed through untouched, and
// a token the panel did not define is not invented here. In English the tokens are already
// the words the panel shows, so the sentence passes through unchanged.
func (a *App) localizeText(text string) string {
	if a.lang == i18n.English {
		return text
	}
	return toolTokenReplacer.Replace(text)
}

// toolTokenReplacer is the sentence-level counterpart of toolWord: the table words each
// cell, this words a token that ended up inside a longer line.
var toolTokenReplacer = strings.NewReplacer(
	"unlocked", "解锁",
	"blocked", "不解锁",
	"unknown", "未知",
)

// reportTable words a result's headers and cells. The tool reports stable tokens for the
// values the panel defined ("unlocked") and its own words for what it measured, which the
// interface leaves alone: a tool is the only thing that knows what its numbers mean.
func (a *App) reportTable(outcome toolOutcome) ([]string, [][]ui.Cell) {
	headers := outcome.result.Headers
	if len(headers) == 0 {
		headers = []string{"item", "value"}
	}
	head := make([]string, len(headers))
	for i, header := range headers {
		head[i] = a.toolWord(header)
	}
	rows := make([][]ui.Cell, 0, len(outcome.result.Rows))
	for _, row := range outcome.result.Rows {
		cells := make([]ui.Cell, 0, len(row))
		for i, value := range row {
			kind := ui.KindPlain
			if i > 0 && len(headers) > 2 {
				// In a table with a status column the second cell carries the verdict.
				kind = toolWordKind(value)
			}
			cells = append(cells, ui.Toned(a.toolWord(value), kind))
		}
		rows = append(rows, cells)
	}
	return head, rows
}

// toolWord localises the tokens this package defines and passes anything else through.
func (a *App) toolWord(value string) string {
	if tools.IsVerdict(value) {
		return tools.Verdict(a.lang, value)
	}
	switch value {
	case "service":
		return a.lang.T("toolbox_col_service")
	case "status":
		return a.lang.T("toolbox_col_status")
	case "region":
		return a.lang.T("toolbox_col_region")
	case "item":
		return a.lang.T("toolbox_col_item")
	case "value":
		return a.lang.T("toolbox_col_value")
	}
	return value
}

// toolWordKind is the tone a verdict word deserves.
func toolWordKind(value string) ui.Kind {
	switch value {
	case "unlocked":
		return ui.KindOK
	case "blocked":
		return ui.KindErr
	case "unknown":
		return ui.KindWarn
	}
	return ui.KindPlain
}

// toolboxBody is the section's 看板: the last outcome of every tool that has run, and a
// count of the ones that have not. It never runs a tool itself.
func (a *App) toolboxBody(w int) []string {
	s := a.style()
	lang := a.lang
	inner := ui.InnerWidth(s, w)

	ran := make([][2]string, 0, len(tools.All()))
	pending := 0
	for _, group := range tools.Groups() {
		for _, tool := range tools.InGroup(group) {
			outcome, ok := a.toolResults[tool.ID]
			if !ok {
				pending++
				continue
			}
			value, kind := a.outcomeLine(outcome)
			ran = append(ran, a.kv("toolbox_"+tool.ID, value, kind))
		}
	}
	if len(ran) == 0 {
		return []string{
			s.Faint(lang.T("toolbox_board_empty")),
			"",
			s.Faint(lang.T("toolbox_board_empty_hint")),
		}
	}
	out := ui.KV(s, ran, inner)
	if pending > 0 {
		out = append(out, "", s.Faint(lang.Format("toolbox_board_pending", pending)))
	}
	return out
}

// outcomeLine is the board's rendering of an outcome: its summary and how long ago it ran,
// or the word for a run that failed. The time comes from the run, not from the moment it is
// read, because a board loaded from disk is showing a measurement taken earlier. The summary
// goes through the same wording as the report, so the board never shows a raw `unlocked 8 ·
// blocked 1 (9)` next to a table that says 解锁.
func (a *App) outcomeLine(o toolOutcome) (string, ui.Kind) {
	if o.err != nil {
		return a.lang.T("toolbox_failed") + " · " + sinceText(a.lang, o.when), ui.KindErr
	}
	summary := a.localizeText(o.result.Summary)
	if summary == "" {
		summary = a.lang.Format("toolbox_rows", len(o.result.Rows))
	}
	return summary + " · " + sinceText(a.lang, o.when), ui.KindOK
}

// sinceText words how long ago a run happened, in the coarse units a board needs.
func sinceText(lang i18n.Lang, when time.Time) string {
	if when.IsZero() {
		return lang.T("toolbox_never")
	}
	d := time.Since(when)
	switch {
	case d < time.Minute:
		return lang.T("toolbox_just_now")
	case d < time.Hour:
		return lang.Format("toolbox_minutes_ago", int(d.Minutes()))
	case d < 24*time.Hour:
		return lang.Format("toolbox_hours_ago", int(d.Hours()))
	default:
		return when.Format("01-02 15:04")
	}
}

// wrapText breaks a sentence onto the card width. Notes are sentences, and a sentence that
// runs past the frame would be cut with no way to read the rest. A line is broken at the last
// space that fits when the text has spaces (a Latin sentence), and at the width when it does
// not (Chinese, a URL), because there is no better place in that case.
func wrapText(text string, width int) []string {
	if width <= 0 {
		return []string{text}
	}
	var lines []string
	rest := text
	for lipgloss.Width(rest) > width {
		used, cut, lastSpace := 0, 0, -1
		for i, r := range rest {
			w := lipgloss.Width(string(r))
			if used+w > width {
				break
			}
			used += w
			cut = i + len(string(r))
			if r == ' ' {
				lastSpace = i
			}
		}
		if cut == 0 {
			break
		}
		if lastSpace > 0 {
			lines = append(lines, rest[:lastSpace])
			rest = strings.TrimLeft(rest[lastSpace+1:], " ")
			continue
		}
		lines = append(lines, rest[:cut])
		rest = rest[cut:]
	}
	if rest != "" {
		lines = append(lines, rest)
	}
	if len(lines) == 0 {
		lines = append(lines, "")
	}
	return lines
}
