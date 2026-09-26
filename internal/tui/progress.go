package tui

import (
	"context"
	"fmt"
	"strings"
	"sync"

	"charm.land/bubbles/v2/spinner"
	"charm.land/bubbles/v2/viewport"
	tea "charm.land/bubbletea/v2"
	"charm.land/lipgloss/v2"

	"github.com/MinimaxFlora/EasySB/internal/i18n"
	"github.com/MinimaxFlora/EasySB/internal/icons"
	"github.com/MinimaxFlora/EasySB/internal/theme"
	"github.com/MinimaxFlora/EasySB/internal/ui"
)

// taskFunc is one unit of work the panel runs on its own goroutine: it writes lines
// through the reporter and returns the error that ends the task.
type taskFunc func(ctx context.Context, r *taskReporter) error

// taskReporter is a running task's link back to the screen that started it: Log for a
// line of output, Progress for a download that is still arriving, SetResult for what
// the screen should keep once the task is done. A task never touches the interface
// directly, so every screen sees its output in the order it was produced.
type taskReporter struct {
	log    func(string)
	prog   func(label string, done, total int64)
	result func(any)
}

// Log appends one line to the task's output.
func (r *taskReporter) Log(line string) {
	if r.log != nil {
		r.log(line)
	}
}

// Progress reports a download in flight, which the task screen draws as a bar rather
// than as a line of output: a line would either flood the log or say nothing.
func (r *taskReporter) Progress(label string, done, total int64) {
	if r.prog != nil {
		r.prog(label, done, total)
	}
}

// SetResult hands a value back to the model once the task is over, for the screens
// whose 看板 shows what the task found: a subscription link grid or an unlock report
// is worth more than the last run's log. Values are read back after taskDoneMsg, on
// the render goroutine, so the model guards the handover.
func (r *taskReporter) SetResult(value any) {
	if r.result != nil {
		r.result(value)
	}
}

// progressScrollStep is how many lines one arrow key scrolls the finished log.
// Three matches the feel of a browser wheel.
const progressScrollStep = 3

type logLineMsg string
type logsClosedMsg struct{}
type taskDoneMsg struct{ err error }

// downloadReading is the live state of the download a task is doing. The task
// goroutine writes it and the render goroutine reads it, so the model guards it.
type downloadReading struct {
	label string
	done  int64
	total int64
	live  bool
}

type progressModel struct {
	title  string
	fn     taskFunc
	cancel context.CancelFunc
	ch     chan string
	errCh  chan error
	logs   []string
	spin   spinner.Model
	vp     viewport.Model
	done   bool
	err    error
	// afterLinks swaps the finished log for the copyable link grid. It is used
	// by subscription tasks, whose only interesting output is the endpoints.
	afterLinks bool
	// noCopy hides the copy key on tasks whose output is a picture, such as the
	// subscription QR codes.
	noCopy bool
	width  int
	height int
	// mu guards dl, which the task goroutine writes while the screen is drawn, and
	// res, which the same goroutine hands over for the section that started it.
	mu  sync.Mutex
	dl  downloadReading
	res any
}

// newProgress builds the model for one task. It returns a pointer because the task
// goroutine records its download readings on the same value the screen draws.
func newProgress(title string, fn taskFunc) *progressModel {
	p := &progressModel{
		title: title,
		fn:    fn,
		ch:    make(chan string, 256),
		errCh: make(chan error, 1),
	}
	p.spin = spinner.New(spinner.WithSpinner(spinner.Line))
	p.vp = viewport.New()
	p.vp.SoftWrap = true
	return p
}

func (p *progressModel) Init() tea.Cmd {
	ctx, cancel := context.WithCancel(context.Background())
	p.cancel = cancel
	fn := p.fn
	ch := p.ch
	errCh := p.errCh
	go func() {
		r := &taskReporter{
			log:    func(s string) { ch <- s },
			prog:   p.setDownload,
			result: p.setResult,
		}
		err := fn(ctx, r)
		errCh <- err
		close(ch)
	}()
	return tea.Batch(p.tickCmd(), waitLog(ch))
}

// setResult records the value the task wants the model to keep. It is called from the
// task goroutine, so it takes the same lock the download reading uses.
func (p *progressModel) setResult(value any) {
	p.mu.Lock()
	p.res = value
	p.mu.Unlock()
}

// taskResult is what the finished task handed over, or nil. It is read on the render
// goroutine once the task is done.
func (p *progressModel) taskResult() any {
	p.mu.Lock()
	defer p.mu.Unlock()
	return p.res
}

// setDownload records one reading of a download. It is called from the task
// goroutine, so it never touches anything but the reading itself.
func (p *progressModel) setDownload(label string, done, total int64) {
	p.mu.Lock()
	p.dl = downloadReading{label: label, done: done, total: total, live: true}
	p.mu.Unlock()
}

// reading returns the current download state.
func (p *progressModel) reading() downloadReading {
	p.mu.Lock()
	defer p.mu.Unlock()
	return p.dl
}

// clearDownload drops the bar: the task is over, so a reading that is no longer
// moving would only be a stale number on a finished screen.
func (p *progressModel) clearDownload() {
	p.mu.Lock()
	p.dl = downloadReading{}
	p.mu.Unlock()
}

// downloadBar draws the download a task is doing: the file, a bar sized to the row and
// the bytes, or the bytes alone when the server announced no length. An empty string
// means nothing is downloading, which is the case for every task that only reads local
// state.
func downloadBar(style theme.Style, ic icons.Set, dl downloadReading, w int) string {
	if !dl.live || w < 24 {
		return ""
	}
	tail := humanBytes(uint64(dl.done))
	if dl.total > 0 {
		tail = fmt.Sprintf("%d%%  %s / %s", dl.done*100/dl.total,
			humanBytes(uint64(dl.done)), humanBytes(uint64(dl.total)))
	}
	head := " " + ic.Download + " "
	barW := w / 3
	if barW < 8 {
		barW = 8
	}
	// The numbers and the bar matter more than the file name, so the label gets
	// whatever is left over once they have their room.
	if labelW := w - lipgloss.Width(head) - lipgloss.Width(tail) - barW - 3; labelW < 8 {
		barW = w - lipgloss.Width(head) - lipgloss.Width(tail) - 11
		if barW < 4 {
			barW = 4
		}
	}
	labelW := w - lipgloss.Width(head) - lipgloss.Width(tail) - barW - 3
	if labelW < 1 {
		labelW = 1
	}
	label := theme.Truncate(dl.label, labelW)
	bar := style.Faint(strings.Repeat("░", barW))
	if dl.total > 0 {
		bar = ui.Meter(style, float64(dl.done)/float64(dl.total), barW)
	}
	line := style.Faint(head) + style.Value(label) + strings.Repeat(" ", labelW-lipgloss.Width(label)) +
		" " + bar + "  " + style.Value(tail)
	return theme.Pad(theme.Truncate(line, w), w)
}

func (p *progressModel) tickCmd() tea.Cmd {
	return func() tea.Msg { return p.spin.Tick() }
}

func waitLog(ch chan string) tea.Cmd {
	return func() tea.Msg {
		line, ok := <-ch
		if !ok {
			return logsClosedMsg{}
		}
		return logLineMsg(line)
	}
}

func waitErr(ch chan error) tea.Cmd {
	return func() tea.Msg { return taskDoneMsg{err: <-ch} }
}

func (p *progressModel) handle(msg tea.Msg) tea.Cmd {
	switch m := msg.(type) {
	case spinner.TickMsg:
		var cmd tea.Cmd
		p.spin, cmd = p.spin.Update(m)
		return cmd
	case logLineMsg:
		p.appendLog(string(m))
		return waitLog(p.ch)
	case logsClosedMsg:
		return waitErr(p.errCh)
	case taskDoneMsg:
		p.done = true
		p.err = m.err
		p.clearDownload()
		if m.err != nil {
			p.appendLog("✗ " + m.err.Error())
		}
		p.refresh()
		return nil
	}
	return nil
}

func (p *progressModel) handleKey(msg tea.KeyPressMsg, lang i18n.Lang) (tea.Cmd, bool) {
	key := strings.ToLower(msg.String())
	if p.done {
		switch key {
		case "enter", "esc", "backspace":
			// q is deliberately absent: it quits the panel from every page, so it
			// reaches the global shortcut instead of dismissing this screen.
			return nil, true
		case "c":
			if p.noCopy {
				break
			}
			text := strings.Join(p.logs, "\n")
			p.appendLog("✓ " + lang.T("copied"))
			return tea.SetClipboard(text), false
		case "up", "k":
			p.vp.ScrollUp(progressScrollStep)
			return nil, false
		case "down", "j":
			p.vp.ScrollDown(progressScrollStep)
			return nil, false
		}
		var cmd tea.Cmd
		p.vp, cmd = p.vp.Update(msg)
		return cmd, false
	}
	if key == "esc" || key == "ctrl+c" {
		if p.cancel != nil {
			p.cancel()
		}
		p.appendLog("✗ cancelled")
		return nil, false
	}
	var cmd tea.Cmd
	p.vp, cmd = p.vp.Update(msg)
	return cmd, false
}

func (p *progressModel) resize(w, h int) {
	w = panelWidth(w)
	p.width, p.height = w, h
	inner := w - 4
	if inner < 10 {
		inner = 10
	}
	// The log sits in a card under the status strip, so the viewport is what is
	// left after the strip, the card borders and the hint bar.
	vh := h - 4 - taskHintRows(h)
	if vh < 1 {
		vh = 1
	}
	p.vp.SetWidth(inner)
	p.vp.SetHeight(vh)
	p.refresh()
}

// taskHintRows is how many rows the hint bar takes, matching the dashboard: a
// boxed hint on a roomy terminal, one line when there is almost no room.
func taskHintRows(h int) int {
	switch {
	case h >= 22:
		return 3
	case h >= 6:
		return 1
	}
	return 0
}

func (p *progressModel) appendLog(line string) {
	p.logs = append(p.logs, line)
	p.refresh()
}

func (p *progressModel) refresh() {
	follow := p.vp.AtBottom()
	p.vp.SetContent(strings.Join(p.logs, "\n"))
	if follow {
		p.vp.GotoBottom()
	}
}

// body is the card's content: the live download bar on top while something is
// arriving, then the log. The bar takes the first row and the log gives up its last
// one, so the frame keeps its size and the screen does not jump when a download starts
// or finishes.
func (p *progressModel) body(style theme.Style, ic icons.Set, width int) []string {
	lines := strings.Split(p.vp.View(), "\n")
	bar := downloadBar(style, ic, p.reading(), ui.InnerWidth(style, width))
	if bar == "" {
		return lines
	}
	if len(lines) < 2 {
		// A one-row card has no room for both, and the live reading is the more
		// useful half of it.
		return []string{bar}
	}
	body := make([]string, 0, len(lines))
	body = append(body, bar)
	return append(body, lines[:len(lines)-1]...)
}

// View draws the task the way the dashboard draws everything else: the live
// status strip on top, the log in a card titled with the task, and the keys on the
// bottom bar. The task screen is where the subscription service, the kernel
// install and the deployment all end up, so it is the one screen that has to look
// like the rest of the panel rather than like a raw console.
func (p *progressModel) View(w, h int, strip string, style theme.Style, lang i18n.Lang, ic icons.Set) string {
	width := panelWidth(w)
	if width != p.width || h != p.height {
		p.resize(width, h)
	}
	pal := style.Palette

	badge := pal.Colored(pal.Primary, p.spin.View()+" "+lang.T("task_running"))
	if p.done {
		if p.err != nil {
			badge = pal.State(ic.Err+" "+lang.T("task_failed"), false, false)
		} else {
			badge = pal.State(ic.OK+" "+lang.T("task_done"), true, false)
		}
	}

	card := ui.Card(style, p.title, badge, p.body(style, ic, width), width)
	lines := make([]string, 0, h)
	if strip != "" {
		lines = append(lines, strip, "")
	}
	lines = append(lines, card...)

	var hint string
	if p.done {
		parts := []string{lang.T("task_scroll")}
		if !p.noCopy {
			parts = append(parts, lang.T("task_copy"))
		}
		parts = append(parts, lang.T("task_press_enter"), lang.T("hint_quit"))
		hint = strings.Join(parts, "  ")
	} else {
		hint = lang.T("hint_back") + "  " + lang.T("cancelled")
	}
	switch taskHintRows(h) {
	case 3:
		lines = append(lines, hintBoxFor(pal, lang, hint, width)...)
	case 1:
		lines = append(lines, hintLineFor(pal, lang, hint, width))
	}
	return ui.Fit(lines, width, h)
}
