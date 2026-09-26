// Package toolbox holds what every toolbox tool reports and what the panel hands it. Each
// tool lives in its own subpackage and knows nothing about the others: a tool returns a
// table, the panel draws it, and adding a tool never means adding a screen.
//
// Two rules shape the tools that live under it, and both come from the panel's job being
// to tell an operator the truth about a host:
//
//   - Everything that reaches outside the process is injected through Options, so a tool
//     is testable without a network, a disk benchmark, or root.
//   - A tool reports what it measured. A value it could not read is a note explaining
//     why, never a plausible-looking zero.
package toolbox

import (
	"context"
	"fmt"
	"net/http"
	"os"
	"path/filepath"
	"sync"
	"time"
)

// DefaultTimeout bounds one tool when the caller does not set one. A benchmark is the
// slowest thing in the toolbox, so this is generous.
const DefaultTimeout = 5 * time.Minute

// Options is what the panel injects into a tool.
type Options struct {
	// Client answers every HTTP request a tool makes. Nil means a client with Timeout.
	Client HTTPDoer
	// Timeout bounds one tool as a whole. Zero means DefaultTimeout.
	Timeout time.Duration
	// Log receives progress lines while the tool runs; a nil Log discards them.
	Log func(string)
	// Scratch is a writable directory for tools that write files (disk benchmarks and
	// speed tests). Empty means a fresh directory under the system temporary directory.
	Scratch string
	// Clock is the only source of "now" for tools that measure elapsed time, so a test
	// can drive them deterministically.
	Clock func() time.Time
}

// HTTPDoer is the part of an HTTP client the toolbox needs.
type HTTPDoer interface {
	Do(*http.Request) (*http.Response, error)
}

// HTTP returns the client a tool should use, defaulting to one with the tool timeout.
func (o Options) HTTP() HTTPDoer {
	if o.Client != nil {
		return o.Client
	}
	return &http.Client{Timeout: o.Duration()}
}

// Duration is the whole-tool budget.
func (o Options) Duration() time.Duration {
	if o.Timeout > 0 {
		return o.Timeout
	}
	return DefaultTimeout
}

// Now is the clock a tool should read.
func (o Options) Now() time.Time {
	if o.Clock != nil {
		return o.Clock()
	}
	return time.Now()
}

// Logf writes one progress line, and does nothing when no Log was injected.
func (o Options) Logf(format string, args ...any) {
	if o.Log != nil {
		o.Log(fmt.Sprintf(format, args...))
	}
}

// ScratchDir returns the directory a tool may write into, creating it on first use.
func (o Options) ScratchDir() string {
	if o.Scratch != "" {
		return o.Scratch
	}
	return filepath.Join(os.TempDir(), "easysb-toolbox")
}

// Result is one tool's output, shaped as a table. The JSON tags are the stored form of the
// board (see SaveBoard): a stored result has to keep loading after a field here is renamed,
// and an explicit name is what makes that possible.
type Result struct {
	// Headers labels the columns. A tool that reports one value per row leaves this
	// empty, and the panel draws a two-column label/value table.
	Headers []string `json:"headers,omitempty"`
	// Rows is the table body: one row, same number of cells, per line of output.
	Rows [][]string `json:"rows,omitempty"`
	// Notes are the lines that do not belong in a cell: where a number came from, why
	// one is missing, what the tool skipped.
	Notes []string `json:"notes,omitempty"`
	// Summary is one short line for the toolbox board, e.g. "解锁 12 · 屏蔽 3".
	Summary string `json:"summary,omitempty"`
}

// Add appends a label/value row.
func (r *Result) Add(label, value string) {
	r.Rows = append(r.Rows, []string{label, value})
}

// Note appends a note line.
func (r *Result) Note(format string, args ...any) {
	r.Notes = append(r.Notes, fmt.Sprintf(format, args...))
}

// Tool describes one entry of the toolbox: the group the menu files it under, and how to
// run it. The registry in internal/toolbox/tools is built from these.
type Tool struct {
	// ID is the node id, the i18n key suffix ("toolbox_"+ID) and the --tool argument.
	ID string
	// Group is one of the group ids the menu lists (unlock, network, ip, hardware).
	Group string
	// Run executes the tool. It must respect ctx and never panic on odd output.
	Run func(context.Context, Options) (Result, error)
}

// SafeLog returns a Log function that serialises calls, for tools that probe concurrently
// and would otherwise interleave their progress lines.
func SafeLog(log func(string)) func(string) {
	if log == nil {
		return nil
	}
	var mu sync.Mutex
	return func(line string) {
		mu.Lock()
		defer mu.Unlock()
		log(line)
	}
}
