package backtrace

import (
	"context"
	"errors"
	"fmt"
	"net"
	"os"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	"golang.org/x/net/icmp"
	"golang.org/x/net/ipv4"
)

// traceConfig bounds one traceroute. The values are what the reference scripts'
// prints come from: walk at most 24 hops, try three times per hop, wait a second
// per try. A silent hop therefore costs the full timeout three times, which is
// why the runner traces several targets at once instead of shortening the wait —
// a reply that takes longer than a second is a reading, not a failure.
type traceConfig struct {
	maxHops int
	probes  int
	timeout time.Duration
}

var defaultTraceConfig = traceConfig{maxHops: 24, probes: 3, timeout: time.Second}

// Hop is one TTL of a traced path.
type Hop struct {
	TTL int
	// IP is the address that answered this TTL, nil when no probe did.
	IP net.IP
	// RTT is the fastest round trip measured at this TTL, zero when nothing
	// answered.
	RTT time.Duration
}

// Path is what one traceroute saw.
type Path struct {
	// Target is the address traced to.
	Target net.IP
	// Hops has one entry per TTL sent, in TTL order, silent hops included: a
	// gap in a path is a fact about the path.
	Hops []Hop
	// Reached is true when the target itself answered, which is what ends a
	// trace before the hop budget runs out.
	Reached bool
}

// LastHop returns the hop nearest the target that answered at all, which is what
// the report's 末跳 column and 时延 column name. The second result is false when
// nothing on the path answered.
func (p Path) LastHop() (Hop, bool) {
	for i := len(p.Hops) - 1; i >= 0; i-- {
		if p.Hops[i].IP != nil {
			return p.Hops[i], true
		}
	}
	return Hop{}, false
}

// Prober traces the path to one target.
//
// A runner builds one prober per run, shares it across targets and closes it when
// the run ends, so an implementation may hold a connection — the real one holds a
// raw socket — as long as it serves several goroutines at once.
type Prober interface {
	Trace(ctx context.Context, dst net.IP) (Path, error)
	Close() error
}

// errHopTimeout is what a socket reports when nothing arrived before the
// deadline. It is not a failure: the tracer counts it as one lost probe and
// tries again.
var errHopTimeout = errors.New("no ICMP reply before the deadline")

// reply is one ICMP answer to a probe.
type reply struct {
	// From is the address that sent it: an intermediate router for a
	// time-exceeded message, the target itself for an echo reply.
	From net.IP
	// Final is true when the target itself answered, which is the signal to
	// stop walking.
	Final bool
}

// socket is the send/receive surface the traceroute loop drives. The real one is
// a raw ICMP socket that only root may open; tests inject a fake, which is how
// the TTL walk, the per-hop probes and the timeout handling are covered without
// a network, root, or a single packet leaving the process.
type socket interface {
	// sendEcho sends one echo request to dst with the given TTL and returns the
	// sequence number that identifies its reply. The number is unique across
	// every probe sharing the socket, because more than one trace uses it.
	sendEcho(dst net.IP, ttl int) (int, error)
	// recv waits for the reply to the probe with that sequence number, until
	// the deadline. Another probe's reply, and a reply that arrives after the
	// deadline, is discarded; a deadline that passes with nothing delivered is
	// errHopTimeout.
	recv(seq int, deadline time.Time) (reply, error)
	close() error
}

// tracer walks paths over one socket. now is injected so a test can drive RTTs
// deterministically.
type tracer struct {
	sock socket
	cfg  traceConfig
	now  func() time.Time
}

// newICMPProber opens the raw socket a trace runs on and returns the prober that
// owns it.
func newICMPProber(cfg traceConfig) (Prober, error) {
	sock, err := openICMPSocket()
	if err != nil {
		return nil, err
	}
	return &tracer{sock: sock, cfg: cfg, now: time.Now}, nil
}

// Trace walks the path to dst. An error means the probe could not be made at
// all; a path that answered nothing is not an error, it is a Path whose hops are
// all silent.
func (t *tracer) Trace(ctx context.Context, dst net.IP) (Path, error) {
	if t.cfg.maxHops <= 0 || t.cfg.probes <= 0 || t.cfg.timeout <= 0 {
		return Path{}, fmt.Errorf("traceroute needs a positive hop budget, probe count and timeout")
	}
	path := Path{Target: dst}
	for ttl := 1; ttl <= t.cfg.maxHops; ttl++ {
		if err := ctx.Err(); err != nil {
			return path, err
		}
		hop := Hop{TTL: ttl}
		for probe := 0; probe < t.cfg.probes; probe++ {
			seq, err := t.sock.sendEcho(dst, ttl)
			if err != nil {
				return path, fmt.Errorf("probing %s at TTL %d: %w", dst, ttl, err)
			}
			sent := t.now()
			deadline := sent.Add(t.cfg.timeout)
			// A cancelled run must not wait out the full hop timeout.
			if d, ok := ctx.Deadline(); ok && d.Before(deadline) {
				deadline = d
			}
			r, err := t.sock.recv(seq, deadline)
			if err != nil {
				if errors.Is(err, errHopTimeout) || errors.Is(err, context.DeadlineExceeded) {
					if cerr := ctx.Err(); cerr != nil {
						return path, cerr
					}
					continue
				}
				return path, fmt.Errorf("reading the ICMP reply at TTL %d: %w", ttl, err)
			}
			if rtt := t.now().Sub(sent); hop.IP == nil || rtt < hop.RTT {
				hop.IP, hop.RTT = r.From, rtt
			}
			if r.Final {
				path.Hops = append(path.Hops, hop)
				path.Reached = true
				return path, nil
			}
		}
		path.Hops = append(path.Hops, hop)
	}
	return path, nil
}

// Close releases the socket.
func (t *tracer) Close() error { return t.sock.close() }

// icmpSocket is the raw ICMP implementation of socket.
//
// It needs a raw socket, so the panel must run as root (or hold CAP_NET_RAW), and
// openICMPSocket turns the kernel's refusal into one sentence naming that.
//
// One socket serves every trace in a run, which is why this type exists instead
// of a connection per trace:
//
//   - The TTL is a socket option, so setting it and writing the packet have to
//     happen together; sendEcho holds one lock across both.
//   - Only one goroutine may read a socket, or two traces would steal each
//     other's replies. A single reader demultiplexes by sequence number, which
//     is why sendEcho allocates one and hands it back to the tracer.
type icmpSocket struct {
	conn *icmp.PacketConn
	p4   *ipv4.PacketConn
	id   int
	seq  atomic.Int32

	sendMu sync.Mutex // serialises SetTTL and the write that follows it

	mu      sync.Mutex
	waiters map[int]chan reply
	readErr error

	closeOnce sync.Once
	done      chan struct{}
}

// openICMPSocket opens the raw socket and starts its reader.
func openICMPSocket() (*icmpSocket, error) {
	conn, err := icmp.ListenPacket("ip4:icmp", "0.0.0.0")
	if err != nil {
		return nil, socketError(err)
	}
	s := &icmpSocket{
		conn: conn,
		// IPv4PacketConn is the same underlying socket, wrapped so the TTL can
		// be set per packet; icmp.PacketConn hands out the instance it caches.
		p4: conn.IPv4PacketConn(),
		// The identifier only has to distinguish this process's probes from
		// anything else that echoes on the same host.
		id:      os.Getpid() & 0xffff,
		waiters: make(map[int]chan reply),
		done:    make(chan struct{}),
	}
	go s.read()
	return s, nil
}

// socketError turns a failed ListenPacket into something an operator can act on.
// Everything the panel does runs as root, so a refusal here means the process
// lost that privilege rather than that anything is misconfigured.
func socketError(err error) error {
	msg := strings.ToLower(err.Error())
	if errors.Is(err, os.ErrPermission) ||
		strings.Contains(msg, "permission denied") ||
		strings.Contains(msg, "operation not permitted") {
		return fmt.Errorf("raw ICMP socket refused (%v): run the panel as root, or grant the binary CAP_NET_RAW", err)
	}
	return fmt.Errorf("opening a raw ICMP socket: %w", err)
}

// sendEcho stamps a unique sequence number on one echo request, registers the
// channel its reply will be delivered on, and sends it with the TTL that bounds
// its life.
//
// The channel is registered before the packet leaves: a router one hop away can
// answer in microseconds, and a reply that arrives before anyone is listening for
// its sequence number would be dropped and cost the probe its whole timeout.
func (s *icmpSocket) sendEcho(dst net.IP, ttl int) (int, error) {
	seq := int(s.seq.Add(1) & 0xffff)
	msg := icmp.Message{
		Type: ipv4.ICMPTypeEcho,
		Code: 0,
		Body: &icmp.Echo{ID: s.id, Seq: seq, Data: []byte("easysb-backtrace")},
	}
	wire, err := msg.Marshal(nil)
	if err != nil {
		return 0, err
	}

	s.mu.Lock()
	if s.readErr != nil {
		err := s.readErr
		s.mu.Unlock()
		return 0, err
	}
	s.waiters[seq] = make(chan reply, 1)
	s.mu.Unlock()

	s.sendMu.Lock()
	err = s.p4.SetTTL(ttl)
	if err == nil {
		_, err = s.conn.WriteTo(wire, &net.IPAddr{IP: dst})
	}
	s.sendMu.Unlock()
	if err != nil {
		s.dropWaiter(seq)
		return 0, err
	}
	return seq, nil
}

// dropWaiter forgets a probe's delivery channel, so a failed send does not leak
// one.
func (s *icmpSocket) dropWaiter(seq int) {
	s.mu.Lock()
	delete(s.waiters, seq)
	s.mu.Unlock()
}

// recv waits for the reply carrying seq.
func (s *icmpSocket) recv(seq int, deadline time.Time) (reply, error) {
	s.mu.Lock()
	ch := s.waiters[seq]
	s.mu.Unlock()
	if ch == nil {
		return reply{}, fmt.Errorf("no probe is outstanding for sequence %d", seq)
	}
	defer s.dropWaiter(seq)

	timer := time.NewTimer(time.Until(deadline))
	defer timer.Stop()
	select {
	case r := <-ch:
		return r, nil
	case <-timer.C:
		return reply{}, errHopTimeout
	case <-s.done:
		s.mu.Lock()
		err := s.readErr
		s.mu.Unlock()
		if err == nil {
			err = errors.New("ICMP socket closed")
		}
		return reply{}, err
	}
}

// read is the socket's only reader. It parses each datagram and delivers it to
// the probe whose sequence number it carries; anything else — another process's
// echo, a reply to a probe that already gave up — is dropped.
func (s *icmpSocket) read() {
	buf := make([]byte, 1500)
	for {
		n, from, err := s.conn.ReadFrom(buf)
		if err != nil {
			if s.closed() {
				return
			}
			s.fail(err)
			return
		}
		seq, final, ok := parseICMP(buf[:n])
		if !ok {
			continue
		}
		s.mu.Lock()
		ch := s.waiters[seq]
		s.mu.Unlock()
		if ch == nil {
			continue
		}
		addr, _ := from.(*net.IPAddr)
		if addr == nil {
			continue
		}
		select {
		case ch <- reply{From: append(net.IP(nil), addr.IP...), Final: final}:
		default: // the probe already gave up; the reply is stale
		}
	}
}

// fail records why the reader stopped, so a waiting recv reports the cause
// instead of blocking until its deadline.
func (s *icmpSocket) fail(err error) {
	s.mu.Lock()
	if s.readErr == nil {
		s.readErr = err
	}
	s.mu.Unlock()
	select {
	case <-s.done:
	default:
		close(s.done)
	}
}

// closed reports whether close ran, which is how the reader tells a socket it
// closed itself from one the kernel took away.
func (s *icmpSocket) closed() bool {
	select {
	case <-s.done:
		return true
	default:
		return false
	}
}

func (s *icmpSocket) close() error {
	var err error
	s.closeOnce.Do(func() {
		close(s.done)
		err = s.conn.Close()
	})
	return err
}

// parseICMP reads the sequence number of our echo request out of a captured ICMP
// message and reports whether it came from the destination. An echo reply
// carries the number directly; a time-exceeded or unreachable message carries the
// header of the probe that provoked it (see embeddedEcho).
func parseICMP(b []byte) (seq int, final bool, ok bool) {
	msg, err := icmp.ParseMessage(ipv4.ICMPTypeEcho.Protocol(), b)
	if err != nil {
		return 0, false, false
	}
	switch body := msg.Body.(type) {
	case *icmp.Echo:
		if msg.Type != ipv4.ICMPTypeEchoReply {
			return 0, false, false // our own echo request, echoed by the kernel
		}
		return body.Seq, true, true
	case *icmp.TimeExceeded:
		_, seq, ok := embeddedEcho(body.Data)
		return seq, false, ok
	case *icmp.DstUnreach:
		// A destination-unreachable from a router on the way is a reading too:
		// it names the hop and stops the walk at the next TTL.
		_, seq, ok := embeddedEcho(body.Data)
		return seq, false, ok
	default:
		return 0, false, false
	}
}

// embeddedEcho recovers the identifier and sequence number of the echo request
// that an ICMP error message quotes. RFC 792 has the router include the IP header
// plus the first eight bytes of the offending datagram, and for an echo request
// those eight bytes are the ICMP header that holds both numbers.
func embeddedEcho(data []byte) (id, seq int, ok bool) {
	if len(data) < 20+8 {
		return 0, 0, false
	}
	ihl := int(data[0]&0x0f) * 4
	if ihl < 20 || len(data) < ihl+8 {
		return 0, 0, false
	}
	if data[9] != 1 { // IP protocol 1 is ICMP; anything else is a message we did not provoke
		return 0, 0, false
	}
	h := data[ihl:]
	id = int(h[4])<<8 | int(h[5])
	seq = int(h[6])<<8 | int(h[7])
	return id, seq, true
}
