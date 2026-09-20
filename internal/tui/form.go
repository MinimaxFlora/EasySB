package tui

import (
	"strings"

	"charm.land/bubbles/v2/textinput"
	tea "charm.land/bubbletea/v2"

	"github.com/MinimaxFlora/EasySB/internal/i18n"
	"github.com/MinimaxFlora/EasySB/internal/theme"
)

// formSubmit applies a submitted value. Returning an error keeps the form open
// and shows the message; a non-nil command is dispatched after the form closes.
type formSubmit func(a *App, value string) (tea.Cmd, error)

type formModel struct {
	title  string
	prompt string
	hint   string
	input  textinput.Model
	submit formSubmit
	err    string
}

func newForm(title, prompt, initial, hint string, submit formSubmit) *formModel {
	in := textinput.New()
	in.Placeholder = ""
	in.CharLimit = 256
	in.SetValue(initial)
	in.CursorEnd()
	in.Focus()
	return &formModel{
		title:  title,
		prompt: prompt,
		hint:   hint,
		input:  in,
		submit: submit,
	}
}

func (f *formModel) update(msg tea.Msg) tea.Cmd {
	var cmd tea.Cmd
	f.input, cmd = f.input.Update(msg)
	return cmd
}

func (f *formModel) resize(w int) {
	width := w - 8
	if width < 16 {
		width = 16
	}
	f.input.SetWidth(width)
}

func (f *formModel) View(w int, pal theme.Palette, lang i18n.Lang) string {
	if w < 40 {
		w = 40
	}
	f.resize(w)

	var b strings.Builder
	b.WriteString(" " + pal.Bold(pal.Primary, f.title) + "\n\n")
	b.WriteString(" " + pal.Value(theme.Truncate(f.prompt, w-3)) + "\n")
	b.WriteString(" " + f.input.View() + "\n\n")
	if f.err != "" {
		b.WriteString(" " + pal.Colored(pal.Err, f.err) + "\n\n")
	}
	hint := lang.T("form_confirm") + "  " + lang.T("form_cancel")
	b.WriteString(" " + pal.Dim(hint))
	return b.String()
}
