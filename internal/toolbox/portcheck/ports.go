package portcheck

import (
	"context"
	"fmt"
	"net"
	"strconv"
)

// smtpPort is the port the verdict turns on. Without 25 reachable from outside
// the host receives no mail from other servers, which is what "自建邮局" means,
// so this one port outranks the rest of the list.
const smtpPort = 25

// Port is one entry of the probe list.
type Port struct {
	// Number is the TCP port dialled.
	Number int
	// Purpose is the cell text: what the port serves.
	Purpose string
	// Mail marks the ports a mail server itself needs. The others are probed
	// because the panel and the certificate flow use them, and the report says
	// so rather than leaving the reading ambiguous.
	Mail bool
}

// catalogue is the probe list in report order. The mail ports come first
// because they are the question this tool answers; 53/80/443 follow because an
// open 80 or 443 is what makes the panel's own certificate flow work.
var catalogue = []Port{
	{Number: 25, Purpose: "SMTP 收信", Mail: true},
	{Number: 465, Purpose: "SMTP over TLS", Mail: true},
	{Number: 587, Purpose: "SMTP 提交", Mail: true},
	{Number: 110, Purpose: "POP3", Mail: true},
	{Number: 995, Purpose: "POP3 over TLS", Mail: true},
	{Number: 143, Purpose: "IMAP", Mail: true},
	{Number: 993, Purpose: "IMAP over TLS", Mail: true},
	{Number: 53, Purpose: "DNS（非邮件）"},
	{Number: 80, Purpose: "HTTP（非邮件）"},
	{Number: 443, Purpose: "HTTPS（非邮件）"},
}

// Ports returns the probe list in report order. It is a copy, so a caller
// cannot reorder the list the report is built from.
func Ports() []Port {
	return append([]Port(nil), catalogue...)
}

// Status is one port's verdict.
type Status string

const (
	// StatusOpen means the TCP handshake completed: something is listening and
	// the path end to end works.
	StatusOpen Status = "open"
	// StatusRefused means the peer answered with a RST. The packet reached the
	// host, so the port is not filtered; nothing is listening on it (or a local
	// firewall rejected it). For a mail port nothing installed yet, this is the
	// best result available.
	StatusRefused Status = "refused"
	// StatusBlocked means nothing answered before the deadline. From inside the
	// host this is the signature of a filtered port — or of a provider that
	// does not loop traffic back, which cannot be told apart here.
	StatusBlocked Status = "blocked"
	// StatusError means the dial failed for a reason that is neither a deadline
	// nor a refusal, so nothing conclusive can be read from it.
	StatusError Status = "error"
	// StatusSkipped means the port was never dialled, because there was no
	// public address to dial.
	StatusSkipped Status = "skipped"
)

// Reachable reports whether the port is not filtered: the packet arrived,
// whether or not something listens on it. This is the question put to the
// provider, and it is what a mail setup needs.
func (s Status) Reachable() bool { return s == StatusOpen || s == StatusRefused }

// Text is the user-facing cell text.
func (s Status) Text() string {
	switch s {
	case StatusOpen:
		return "开放"
	case StatusRefused:
		return "可达(未监听)"
	case StatusBlocked:
		return "超时"
	case StatusSkipped:
		return "未检测"
	default:
		return "错误"
	}
}

// PortResult is one port's measurement.
type PortResult struct {
	Port   Port
	Status Status
	// Error is the dial error text, empty when the handshake completed. A
	// refusal carries one too: the refusal is the measurement, and its text is
	// worth keeping for the log.
	Error string
}

// short is the one-cell form the summary uses.
func (p PortResult) short() string {
	switch p.Status {
	case StatusOpen, StatusRefused:
		return fmt.Sprintf("%d 通", p.Port.Number)
	case StatusBlocked:
		return fmt.Sprintf("%d 不通", p.Port.Number)
	case StatusSkipped:
		return fmt.Sprintf("%d 未检测", p.Port.Number)
	default:
		return fmt.Sprintf("%d 检测失败", p.Port.Number)
	}
}

// probe dials one port on the host's own public address. The address is the
// point of the test: 127.0.0.1 would prove only that the local stack works,
// while the public address puts the packet through the provider's edge and the
// local firewall, which is where a mail port gets blocked.
func (o Options) probe(ctx context.Context, p Port, ip string) PortResult {
	addr := net.JoinHostPort(ip, strconv.Itoa(p.Number))
	dctx, cancel := context.WithTimeout(ctx, o.dialTimeout())
	defer cancel()

	conn, err := o.dialer().DialContext(dctx, "tcp4", addr)
	if conn != nil {
		// The handshake is the whole measurement: nothing is written, nothing
		// is read, and an open connection must not be left behind.
		conn.Close()
	}
	res := PortResult{Port: p, Status: classify(err)}
	if err != nil {
		res.Error = err.Error()
	}
	return res
}

// classify turns a dial outcome into a status. A deadline is the only evidence
// of filtering that a dial can produce; anything else that is not a refusal is
// reported as an error rather than guessed at.
func classify(err error) Status {
	switch {
	case err == nil:
		return StatusOpen
	case isTimeout(err):
		return StatusBlocked
	case isRefused(err):
		return StatusRefused
	default:
		return StatusError
	}
}
