package backtrace

import (
	"context"
	"errors"
	"net"
	"os"
	"strings"
	"testing"
	"time"

	"golang.org/x/net/icmp"
	"golang.org/x/net/ipv4"
)

// testClock is a clock a test moves by hand, so a traceroute's measured RTTs are
// whatever the script says instead of whatever the machine did.
type testClock struct{ at time.Time }

func newTestClock() *testClock {
	return &testClock{at: time.Date(2026, 9, 26, 12, 0, 0, 0, time.UTC)}
}

func (c *testClock) now() time.Time      { return c.at }
func (c *testClock) add(d time.Duration) { c.at = c.at.Add(d) }

// step is the scripted outcome of one probe.
type step struct {
	// ip is the router that answers; empty means the probe timed out.
	ip string
	// final marks an answer from the destination itself.
	final bool
	// delay is how long the reply takes, which is how far the clock moves.
	delay time.Duration
	// err replaces the reply with a fatal socket error.
	err error
}

// fakeSocket plays a script: a function of the TTL and the probe index decides
// what each probe does, so nothing leaves the process and no packet exists.
type fakeSocket struct {
	clock *testClock
	step  func(ttl, probe int) step
	// sendErrAt makes the send at that TTL fail; zero never fails.
	sendErrAt int

	sends  []int
	counts map[int]int
	probes map[int]int
	closed bool
}

func newFakeSocket(clock *testClock, s func(ttl, probe int) step) *fakeSocket {
	return &fakeSocket{clock: clock, step: s, counts: map[int]int{}, probes: map[int]int{}}
}

// script answers every TTL the way the map says and times out where it is silent.
func script(m map[int]step) func(ttl, probe int) step {
	return func(ttl, _ int) step { return m[ttl] }
}

func (f *fakeSocket) sendEcho(_ net.IP, ttl int) (int, error) {
	if f.sendErrAt != 0 && ttl == f.sendErrAt {
		return 0, errors.New("send failed")
	}
	f.sends = append(f.sends, ttl)
	seq := len(f.sends)
	f.probes[seq] = f.counts[ttl]
	f.counts[ttl]++
	return seq, nil
}

func (f *fakeSocket) recv(seq int, _ time.Time) (reply, error) {
	ttl := f.sends[seq-1]
	st := f.step(ttl, f.probes[seq])
	if st.err != nil {
		return reply{}, st.err
	}
	f.clock.add(st.delay)
	if st.ip == "" {
		return reply{}, errHopTimeout
	}
	return reply{From: net.ParseIP(st.ip), Final: st.final}, nil
}

func (f *fakeSocket) close() error {
	f.closed = true
	return nil
}

// newTestTracer wires a tracer over the fake socket and the manual clock.
func newTestTracer(clock *testClock, sock socket, cfg traceConfig) *tracer {
	return &tracer{sock: sock, cfg: cfg, now: clock.now}
}

func TestTraceWalksToTheTarget(t *testing.T) {
	clock := newTestClock()
	sock := newFakeSocket(clock, script(map[int]step{
		1: {ip: "192.0.2.1", delay: 5 * time.Millisecond},
		2: {ip: "198.51.100.1", delay: 8 * time.Millisecond},
		3: {ip: "203.0.113.7", delay: 12 * time.Millisecond, final: true},
	}))
	tr := newTestTracer(clock, sock, traceConfig{maxHops: 24, probes: 3, timeout: time.Second})

	path, err := tr.Trace(context.Background(), net.ParseIP("203.0.113.7"))
	if err != nil {
		t.Fatalf("Trace: %v", err)
	}
	if !path.Reached {
		t.Error("path should be marked reached: the destination answered")
	}
	if len(path.Hops) != 3 {
		t.Fatalf("hops = %d, want 3", len(path.Hops))
	}
	last, ok := path.LastHop()
	if !ok {
		t.Fatal("LastHop reported no answer")
	}
	if got := last.IP.String(); got != "203.0.113.7" {
		t.Errorf("last hop = %s, want 203.0.113.7", got)
	}
	if last.RTT != 12*time.Millisecond {
		t.Errorf("last hop RTT = %v, want 12ms", last.RTT)
	}
	// Three probes at TTL 1, three at TTL 2, and the trace stops on the first
	// answer from the destination.
	if len(sock.sends) != 7 {
		t.Errorf("probes sent = %d, want 7", len(sock.sends))
	}
}

func TestTraceKeepsTheFastestProbe(t *testing.T) {
	clock := newTestClock()
	delays := []time.Duration{40 * time.Millisecond, 10 * time.Millisecond, 20 * time.Millisecond}
	sock := newFakeSocket(clock, func(ttl, probe int) step {
		if ttl == 1 {
			return step{ip: "192.0.2.1", delay: delays[probe]}
		}
		return step{ip: "203.0.113.7", final: true, delay: time.Millisecond}
	})
	tr := newTestTracer(clock, sock, traceConfig{maxHops: 4, probes: 3, timeout: time.Second})

	path, err := tr.Trace(context.Background(), net.ParseIP("203.0.113.7"))
	if err != nil {
		t.Fatalf("Trace: %v", err)
	}
	if got := path.Hops[0].RTT; got != 10*time.Millisecond {
		t.Errorf("hop 1 RTT = %v, want the fastest of the three probes (10ms)", got)
	}
}

func TestTraceRecordsASilentHop(t *testing.T) {
	clock := newTestClock()
	sock := newFakeSocket(clock, script(map[int]step{
		1: {ip: "192.0.2.1", delay: time.Millisecond},
		3: {ip: "198.51.100.2", delay: 2 * time.Millisecond},
	}))
	tr := newTestTracer(clock, sock, traceConfig{maxHops: 3, probes: 3, timeout: time.Second})

	path, err := tr.Trace(context.Background(), net.ParseIP("203.0.113.7"))
	if err != nil {
		t.Fatalf("Trace: %v", err)
	}
	if path.Reached {
		t.Error("path must not be marked reached: the destination never answered")
	}
	if len(path.Hops) != 3 {
		t.Fatalf("hops = %d, want 3 (a silence is a row)", len(path.Hops))
	}
	if path.Hops[1].IP != nil {
		t.Errorf("hop 2 = %v, want no answer", path.Hops[1].IP)
	}
	last, ok := path.LastHop()
	if !ok || last.IP.String() != "198.51.100.2" {
		t.Errorf("LastHop = %v/%v, want 198.51.100.2", last.IP, ok)
	}
	if len(sock.sends) != 9 {
		t.Errorf("probes sent = %d, want 9 (three per hop, a timeout is retried)", len(sock.sends))
	}
}

func TestTraceStopsAtTheHopBudget(t *testing.T) {
	clock := newTestClock()
	sock := newFakeSocket(clock, script(nil))
	tr := newTestTracer(clock, sock, traceConfig{maxHops: 2, probes: 2, timeout: time.Second})

	path, err := tr.Trace(context.Background(), net.ParseIP("203.0.113.7"))
	if err != nil {
		t.Fatalf("Trace: %v", err)
	}
	if len(path.Hops) != 2 {
		t.Errorf("hops = %d, want 2", len(path.Hops))
	}
	if _, ok := path.LastHop(); ok {
		t.Error("LastHop should report nothing on a path nothing answered on")
	}
	if len(sock.sends) != 4 {
		t.Errorf("probes sent = %d, want 4", len(sock.sends))
	}
}

func TestTraceErrors(t *testing.T) {
	tests := []struct {
		name  string
		cfg   traceConfig
		ctx   func() context.Context
		sock  func(*testClock) *fakeSocket
		want  string
		hops  int
		probe string
	}{
		{
			name: "send fails",
			cfg:  traceConfig{maxHops: 4, probes: 3, timeout: time.Second},
			ctx:  context.Background,
			sock: func(c *testClock) *fakeSocket {
				s := newFakeSocket(c, script(map[int]step{1: {ip: "192.0.2.1"}}))
				s.sendErrAt = 2
				return s
			},
			want: "probing",
			hops: 1,
		},
		{
			name: "reading fails",
			cfg:  traceConfig{maxHops: 4, probes: 3, timeout: time.Second},
			ctx:  context.Background,
			sock: func(c *testClock) *fakeSocket {
				return newFakeSocket(c, func(int, int) step { return step{err: errors.New("socket died")} })
			},
			want: "reading the ICMP reply",
		},
		{
			name: "cancelled run",
			cfg:  traceConfig{maxHops: 4, probes: 3, timeout: time.Second},
			ctx: func() context.Context {
				ctx, cancel := context.WithCancel(context.Background())
				cancel()
				return ctx
			},
			sock:  func(c *testClock) *fakeSocket { return newFakeSocket(c, script(nil)) },
			want:  context.Canceled.Error(),
			probe: "no probe may be sent for a run that is already cancelled",
		},
		{
			name: "impossible config",
			cfg:  traceConfig{maxHops: 4, probes: 3},
			ctx:  context.Background,
			sock: func(c *testClock) *fakeSocket { return newFakeSocket(c, script(nil)) },
			want: "positive hop budget",
		},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			clock := newTestClock()
			sock := tt.sock(clock)
			tr := newTestTracer(clock, sock, tt.cfg)
			path, err := tr.Trace(tt.ctx(), net.ParseIP("203.0.113.7"))
			if err == nil {
				t.Fatalf("Trace returned no error, want one containing %q", tt.want)
			}
			if !strings.Contains(err.Error(), tt.want) {
				t.Errorf("error = %q, want it to contain %q", err, tt.want)
			}
			if len(path.Hops) != tt.hops {
				t.Errorf("hops = %d, want %d", len(path.Hops), tt.hops)
			}
			if tt.probe != "" && len(sock.sends) != 0 {
				t.Errorf("probes sent = %d, want none", len(sock.sends))
			}
		})
	}
}

func TestTracerCloseReleasesTheSocket(t *testing.T) {
	clock := newTestClock()
	sock := newFakeSocket(clock, script(nil))
	tr := newTestTracer(clock, sock, traceConfig{maxHops: 1, probes: 1, timeout: time.Second})
	if err := tr.Close(); err != nil {
		t.Fatalf("Close: %v", err)
	}
	if !sock.closed {
		t.Error("Close did not release the socket")
	}
}

func TestParseICMP(t *testing.T) {
	// A destination that answers us.
	replyWire := wire(t, icmp.Message{Type: ipv4.ICMPTypeEchoReply, Body: &icmp.Echo{ID: 7, Seq: 42}})
	// Our own echo request seen on the wire: same family, not a reply.
	requestWire := wire(t, icmp.Message{Type: ipv4.ICMPTypeEcho, Body: &icmp.Echo{ID: 7, Seq: 42}})
	// A router that ran out of TTL quoting our probe.
	quoted := ipHeader(1) // ICMP
	quoted = append(quoted, 8, 0, 0, 0, 0x00, 0x07, 0x00, 0x2a)
	timeExceededWire := wire(t, icmp.Message{Type: ipv4.ICMPTypeTimeExceeded, Body: &icmp.TimeExceeded{Data: quoted}})
	// A router that could not deliver, also quoting our probe.
	unreachableWire := wire(t, icmp.Message{Type: ipv4.ICMPTypeDestinationUnreachable, Body: &icmp.DstUnreach{Data: quoted}})

	tests := []struct {
		name  string
		wire  []byte
		seq   int
		final bool
		ok    bool
	}{
		{"echo reply from the target", replyWire, 42, true, true},
		{"our own echo request", requestWire, 0, false, false},
		{"time exceeded from a router", timeExceededWire, 42, false, true},
		{"destination unreachable from a router", unreachableWire, 42, false, true},
		{"nothing at all", nil, 0, false, false},
		{"truncated", []byte{0x00, 0x00}, 0, false, false},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			seq, final, ok := parseICMP(tt.wire)
			if ok != tt.ok || final != tt.final || (ok && seq != tt.seq) {
				t.Errorf("parseICMP = (%d, %v, %v), want (%d, %v, %v)", seq, final, ok, tt.seq, tt.final, tt.ok)
			}
		})
	}
}

func TestEmbeddedEcho(t *testing.T) {
	valid := append(ipHeader(1), 8, 0, 0, 0, 0x12, 0x34, 0xab, 0xcd)
	// An IPv4 header whose length field says 24 bytes, then the ICMP header.
	withOptions := append(ipHeader(1), 0, 0, 0, 0)
	withOptions = append(withOptions, 8, 0, 0, 0, 0x12, 0x34, 0xab, 0xcd)
	withOptions[0] = 0x46

	tests := []struct {
		name string
		data []byte
		id   int
		seq  int
		ok   bool
	}{
		{"quoted echo request", valid, 0x1234, 0xabcd, true},
		{"header with options", withOptions, 0x1234, 0xabcd, true},
		{"too short for a header", valid[:10], 0, 0, false},
		{"header only", ipHeader(1), 0, 0, false},
		{"not ICMP quoted", append(ipHeader(6), 8, 0, 0, 0, 0, 0, 0, 0), 0, 0, false},
		{"header length below the minimum", append([]byte{0x40}, valid[1:]...), 0, 0, false},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			id, seq, ok := embeddedEcho(tt.data)
			if ok != tt.ok || (ok && (id != tt.id || seq != tt.seq)) {
				t.Errorf("embeddedEcho = (%d, %d, %v), want (%d, %d, %v)", id, seq, ok, tt.id, tt.seq, tt.ok)
			}
		})
	}
}

func TestSocketErrorNamesRoot(t *testing.T) {
	tests := []struct {
		name string
		err  error
		want []string
		drop []string
	}{
		{
			name: "permission denied",
			err:  os.ErrPermission,
			want: []string{"raw ICMP socket refused", "root", "CAP_NET_RAW"},
		},
		{
			name: "the kernel's own wording",
			err:  &net.OpError{Op: "listen", Net: "ip4:icmp", Err: errors.New("socket: operation not permitted")},
			want: []string{"root"},
		},
		{
			name: "anything else is not a privilege problem",
			err:  &net.OpError{Op: "listen", Err: errors.New("too many open files")},
			want: []string{"opening a raw ICMP socket"},
			drop: []string{"root"},
		},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			err := socketError(tt.err)
			if err == nil {
				t.Fatal("socketError returned nil")
			}
			for _, want := range tt.want {
				if !strings.Contains(err.Error(), want) {
					t.Errorf("error = %q, want it to contain %q", err, want)
				}
			}
			for _, drop := range tt.drop {
				if strings.Contains(err.Error(), drop) {
					t.Errorf("error = %q, must not mention %q", err, drop)
				}
			}
			// The raw cause must stay readable, so an operator can tell a
			// privilege problem from anything else the kernel said.
			if !strings.Contains(err.Error(), tt.err.Error()) {
				t.Errorf("error = %q, want the original %q preserved", err, tt.err)
			}
		})
	}
}

func TestHopIPsDeduplicatesAndSorts(t *testing.T) {
	outcomes := []outcome{
		{path: Path{Hops: []Hop{
			{TTL: 1, IP: net.ParseIP("198.51.100.2")},
			{TTL: 2, IP: net.ParseIP("203.0.113.9")},
			{TTL: 3},
		}}},
		{path: Path{Hops: []Hop{
			{TTL: 1, IP: net.ParseIP("203.0.113.9")},
			{TTL: 2, IP: net.ParseIP("192.0.2.1")},
		}}},
	}
	got := hopIPs(outcomes)
	want := []string{"192.0.2.1", "198.51.100.2", "203.0.113.9"}
	if len(got) != len(want) {
		t.Fatalf("hopIPs = %v, want %v", got, want)
	}
	for i := range want {
		if got[i].String() != want[i] {
			t.Errorf("hopIPs[%d] = %s, want %s", i, got[i], want[i])
		}
	}
	if len(hopIPs(nil)) != 0 {
		t.Error("hopIPs(nil) should be empty")
	}
}

// wire marshals an ICMP message the way the socket sees it.
func wire(t *testing.T, msg icmp.Message) []byte {
	t.Helper()
	b, err := msg.Marshal(nil)
	if err != nil {
		t.Fatalf("marshal: %v", err)
	}
	return b
}

// ipHeader builds a minimal IPv4 header for the given protocol.
func ipHeader(proto byte) []byte {
	h := make([]byte, 20)
	h[0] = 0x45
	h[9] = proto
	return h
}
