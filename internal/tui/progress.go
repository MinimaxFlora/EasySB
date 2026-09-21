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

// progressScrollStep is how many lines one arrow key or mouse-wheel notch
// scrolls the finished log. Three matches the feel of a browser wheel.
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
	mouse  bool
	width  int
	height int
}

func newProgress(title string, fn taskFunc) progressModel {
	p := progressModel{
		title: title,
		fn:    fn,
		ch:    make(chan string, 256),
		errCh: make(chan error, 1),
		mouse: true,
	}
	p.spin = spinner.New(spinner.WithSpinner(spinner.Line))
	p.vp = viewport.New()
	p.vp.SoftWrap = true
	p.vp.MouseWheelDelta = progressScrollStep
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
	case tea.MouseWheelMsg:
		// Mouse mode is only enabled while a task is on screen, so wheel
		// events belong to the log viewport.
		var cmd tea.Cmd
		p.vp, cmd = p.vp.Update(m)
		return cmd
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
	// Mouse capture is only needed for wheel scrolling; turning it off restores
	// the terminal's own click-drag text selection.
	if key == "m" {
		p.mouse = !p.mouse
		if p.mouse {
			p.appendLog(lang.T("mouse_on"))
		} else {
			p.appendLog(lang.T("mouse_off"))
		}
		return nil, false
	}
	if p.done {
		switch key {
		case "enter", "esc", "q", "backspace":
			return nil, true
		case "c":
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
	p.width, p.height = w, h
	inner := w - 4
	if inner < 10 {
		inner = 10
	}
	vh := h - 9
	if vh < 3 {
		vh = 3
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
	width := w
	if width < 44 {
		width = 44
	}
	if w != p.width || h != p.height {
		p.resize(w, h)
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
	body := theme.Box(lang.T("task_running"), p.vp.View(), width, pal.Border, pal.Primary)
	plain := " " + lang.T("task_scroll") + "  " + lang.T("task_copy") + "  " + lang.T("task_mouse") + "  " + lang.T("task_press_enter")
	if !p.done {
		plain = " " + lang.T("hint_back") + "  " + lang.T("cancelled")
	}
	footer := pal.Dim(theme.Truncate(plain, width))
	return header + "\n\n" + body + "\n" + footer
}
