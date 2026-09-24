package stats

import (
	"context"
	"errors"
	"time"

	"github.com/MinimaxFlora/EasySB/internal/state"
	"github.com/MinimaxFlora/EasySB/internal/user"
)

// DefaultInterval is how often the counters are sampled when the node state does
// not say otherwise.
const DefaultInterval = 5 * time.Minute

// Options configures an accounting Loop. Every dependency is injectable, so the
// policy can be tested without a core, a clock or a disk.
type Options struct {
	// AccountsPath is the account file the loop reads and rewrites.
	AccountsPath string
	// Node returns the node state, which carries the ports and the sync interval.
	Node func() state.Config
	// Dial opens a counter source. It is called once per cycle, so a restarted
	// core is picked up without keeping a stale connection.
	Dial func() (Counter, error)
	// Apply renders the node configuration for the given accounts, validates it
	// and restarts the core.
	Apply func(ctx context.Context, cfg state.Config, users []user.User) error
	// Interval overrides the node's sync interval when non-zero.
	Interval time.Duration
	// Now overrides the clock in tests.
	Now func() time.Time
	// Log receives one line per notable event.
	Log func(string)
}

// Loop keeps the counters and the accounts the core accepts in step with
// reality: it samples the counters, adds the deltas, applies the monthly reset
// and asks for a restart only when an account crossed a quota or expiry line.
type Loop struct {
	opts Options
	// sample is the previous absolute reading, keyed by core user name.
	sample Counters
	// sampled records whether sample can be subtracted from; the first cycle only
	// establishes the baseline.
	sampled bool
}

// New prepares an accounting loop.
func New(opts Options) *Loop {
	return &Loop{opts: opts}
}

// Run samples until ctx is cancelled. It ticks once immediately, because the
// service may have been started precisely to apply a policy change.
func (l *Loop) Run(ctx context.Context) error {
	l.log("accounting every " + l.interval().String())
	for {
		if err := l.Tick(ctx); err != nil && ctx.Err() == nil {
			l.log("accounting: " + err.Error())
		}
		select {
		case <-ctx.Done():
			return nil
		case <-time.After(l.interval()):
		}
	}
}

// Tick runs one accounting cycle.
func (l *Loop) Tick(ctx context.Context) error {
	now := l.now()
	store, err := user.Load(l.opts.AccountsPath)
	if err != nil {
		return err
	}
	if store.Len() == 0 {
		l.sample, l.sampled = nil, false
		return nil
	}

	names := make([]string, 0, store.Len())
	for _, u := range store.Users() {
		names = append(names, u.Token)
	}
	counters, err := l.counters(ctx, names)
	if err != nil {
		return err
	}
	deltas := diffCounters(l.sample, counters, l.sampled)
	l.sample, l.sampled = counters, true

	changed := false
	store.Mutate(func(u *user.User) {
		if d, ok := deltas[u.Token]; ok {
			u.AddUsage(d.Upload, d.Download)
			changed = true
		}
		if u.ResetIfNewMonth(now) {
			changed = true
		}
	})

	// A restart is only needed when the set of accounts the core accepts has to
	// change; accounting itself never touches the running core. A loop without an
	// applier only keeps the counters correct, which is what tests exercise.
	if l.opts.Apply != nil && transitions(store, now) {
		if err := l.opts.Apply(ctx, l.opts.Node(), store.Routable(now)); err != nil {
			return err
		}
		store.MarkApplied(now)
		changed = true
	}
	if !changed {
		return nil
	}
	return store.Save()
}

// counters opens a source and reads the absolute counters of the given users.
func (l *Loop) counters(ctx context.Context, names []string) (Counters, error) {
	if l.opts.Dial == nil {
		return nil, errors.New("stats: no counter source")
	}
	source, err := l.opts.Dial()
	if err != nil {
		return nil, err
	}
	defer source.Close()
	return source.Counters(ctx, names)
}

// transitions reports whether the accounts the core accepts have to change,
// which is the only reason the accounting loop restarts it.
func transitions(store *user.Store, now time.Time) bool {
	live := make(map[string]bool, store.Len())
	for _, u := range store.Routable(now) {
		live[u.Token] = true
	}
	for _, u := range store.Users() {
		if u.Applied != live[u.Token] {
			return true
		}
	}
	return false
}

// diffCounters subtracts a previous sample from the current one.
//
// A counter that went backwards means the core restarted and its counters
// restarted with it, so that account's delta is zero and the baseline moves. A
// user missing from the previous sample is charged its whole reading instead:
// that traffic happened while nobody was accounting for it, and undercounting a
// quota is the worse error.
func diffCounters(prev, cur Counters, sampled bool) Counters {
	out := Counters{}
	if !sampled {
		return out
	}
	for name, c := range cur {
		p := prev[name]
		up, down := c.Upload-p.Upload, c.Download-p.Download
		if up < 0 {
			up = 0
		}
		if down < 0 {
			down = 0
		}
		if up != 0 || down != 0 {
			out[name] = Usage{Upload: up, Download: down}
		}
	}
	return out
}

func (l *Loop) interval() time.Duration {
	if l.opts.Interval > 0 {
		return l.opts.Interval
	}
	if l.opts.Node != nil {
		if d := l.opts.Node().SyncInterval(); d > 0 {
			return d
		}
	}
	return DefaultInterval
}

func (l *Loop) now() time.Time {
	if l.opts.Now != nil {
		return l.opts.Now()
	}
	return time.Now()
}

func (l *Loop) log(line string) {
	if l.opts.Log != nil {
		l.opts.Log(line)
	}
}
