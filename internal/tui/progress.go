package tui

import (
	"context"
	"strings"

	"charm.land/bubbles/v2/spinner"
	"charm.land/bubbles/v2/viewport"
	tea "charm.land/bubbletea/v2"

	"github.com/MinimaxFlora/EasySB/internal/i18n"
	"github.com/MinimaxFlora/EasySB/internal/icons"
	"github.com/MinimaxFlora/EasySB/internal/theme"
)

type taskFunc func(ctx context.Context, log func(string)) error

// progressScrollStep is how many lines one arrow key scrolls the finished log.
// Three matches the feel of a browser wheel.
const progressScrollStep = 3

type logLineMsg string
type logsClosedMsg struct{}
type taskDoneMsg struct{ err error }

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
}

func newProgress(title string, fn taskFunc) progressModel {
	p := progressModel{
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
		err := fn(ctx, func(s string) { ch <- s })
		errCh <- err
		close(ch)
	}()
	return tea.Batch(p.tickCmd(), waitLog(ch))
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
		case "enter", "esc", "q", "backspace":
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
	// The viewport fills the frame between the top/bottom borders, the header
	// row and its trailing blank.
	vh := panelBodyHeight(h) - 2
	if vh < 1 {
		vh = 1
	}
	p.vp.SetWidth(inner)
	p.vp.SetHeight(vh)
	p.refresh()
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

func (p *progressModel) View(w, h int, pal theme.Palette, lang i18n.Lang, ic icons.Set) string {
	width := panelWidth(w)
	if width != p.width || h != p.height {
		p.resize(width, h)
	}

	var status string
	if p.done {
		if p.err != nil {
			status = pal.State(ic.Err+" "+lang.T("task_failed"), false, false)
		} else {
			status = pal.State(ic.OK+" "+lang.T("task_done"), true, false)
		}
	} else {
		status = pal.Colored(pal.Primary, p.spin.View()+" "+lang.T("task_running"))
	}

	header := " " + status + "  " + pal.Dim(theme.Truncate(p.title, width-24))
	body := make([]string, 0, p.vp.Height()+2)
	body = append(body, header, "")
	body = append(body, strings.Split(p.vp.View(), "\n")...)

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
	return framePanel(pal, lang, width, h, body, pal.Dim(hint))
}
