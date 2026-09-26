package portcheck

import (
	"context"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"os"
	"strconv"
	"strings"
	"sync"
	"testing"
	"time"
)

// testIP is TEST-NET-3, the address block reserved for documentation. Using a
// reserved address keeps a stray real dial in a test harmless.
const testIP = "203.0.113.7"

// errDeadline is what a dial that runs into its deadline returns: the net
// package's own form, so the classification has to recognise it the way it
// recognises a real timeout.
func errDeadline() error {
	return &net.OpError{Op: "dial", Net: "tcp4", Err: os.ErrDeadlineExceeded}
}

// errRefused is a peer's RST, carrying the errno of the platform the test runs
// on so the refusal path is exercised on both.
func errRefused() error {
	return fmt.Errorf("dial tcp4: connect: %w", errnoConnRefused)
}

// nopConn stands in for a completed handshake. Close is the only method a probe
// calls, and an embedded nil interface makes any other call panic loudly.
type nopConn struct{ net.Conn }

func (nopConn) Close() error { return nil }

// dialAnswer is one port's canned outcome.
type dialAnswer struct {
	conn net.Conn
	err  error
}

// fakeDialer answers per port number. Every call is recorded, so a test can
// assert what was dialled and that nothing reached the network.
type fakeDialer struct {
	t      *testing.T
	answer func(port int) dialAnswer

	mu   sync.Mutex
	seen []string
}

func (d *fakeDialer) DialContext(_ context.Context, network, addr string) (net.Conn, error) {
	d.mu.Lock()
	d.seen = append(d.seen, network+"|"+addr)
	d.mu.Unlock()

	if network != "tcp4" {
		d.t.Errorf("dial network = %q, want tcp4", network)
	}
	host, portText, err := net.SplitHostPort(addr)
	if err != nil {
		d.t.Errorf("dial address %q: %v", addr, err)
		return nil, err
	}
	if host != testIP {
		d.t.Errorf("dial host = %q, want the public IP %q", host, testIP)
	}
	port, err := strconv.Atoi(portText)
	if err != nil {
		d.t.Errorf("dial port %q: %v", portText, err)
		return nil, err
	}
	a := d.answer(port)
	if a.err != nil {
		return nil, a.err
	}
	return a.conn, nil
}

func (d *fakeDialer) addresses() []string {
	d.mu.Lock()
	defer d.mu.Unlock()
	return append([]string(nil), d.seen...)
}

// ptrAnswer and hostAnswer are one canned DNS answer each.
type ptrAnswer struct {
	names []string
	err   error
}

type hostAnswer struct {
	addrs []string
	err   error
}

// fakeResolver answers PTR and forward lookups from two tables. A question it
// was not told about fails the test, so a probe that starts querying something
// new is noticed instead of reaching a real resolver.
type fakeResolver struct {
	t    *testing.T
	ptr  map[string]ptrAnswer
	host map[string]hostAnswer

	mu   sync.Mutex
	seen []string
}

func (r *fakeResolver) LookupAddr(_ context.Context, addr string) ([]string, error) {
	r.record("PTR " + addr)
	a, ok := r.ptr[addr]
	if !ok {
		r.t.Errorf("unrouted PTR lookup: %s", addr)
		return nil, fmt.Errorf("no PTR answer for %s", addr)
	}
	return a.names, a.err
}

func (r *fakeResolver) LookupHost(_ context.Context, host string) ([]string, error) {
	r.record("A " + host)
	a, ok := r.host[host]
	if !ok {
		r.t.Errorf("unrouted forward lookup: %s", host)
		return nil, fmt.Errorf("no forward answer for %s", host)
	}
	return a.addrs, a.err
}

func (r *fakeResolver) record(q string) {
	r.mu.Lock()
	defer r.mu.Unlock()
	r.seen = append(r.seen, q)
}

// fakeHTTP answers the public IPv4 request.
type fakeHTTP struct {
	t      *testing.T
	body   string
	status int
	err    error

	mu   sync.Mutex
	urls []string
}

func (c *fakeHTTP) Do(req *http.Request) (*http.Response, error) {
	c.mu.Lock()
	c.urls = append(c.urls, req.URL.String())
	c.mu.Unlock()

	if c.err != nil {
		return nil, c.err
	}
	status := c.status
	if status == 0 {
		status = http.StatusOK
	}
	return &http.Response{
		StatusCode: status,
		Header:     http.Header{},
		Body:       io.NopCloser(strings.NewReader(c.body)),
		Request:    req,
	}, nil
}

func (c *fakeHTTP) requests() []string {
	c.mu.Lock()
	defer c.mu.Unlock()
	return append([]string(nil), c.urls...)
}

// checkCase is one table entry: what the world answers, and what the report
// must say about it.
type checkCase struct {
	name string

	// Inputs.
	publicIP string                    // Options.PublicIP; empty means discover
	ipURL    string                    // Options.IPURL; empty means DefaultIPURL
	ipBody   string                    // discovery answer body
	ipStatus int                       // discovery status; zero means 200
	ipErr    error                     // discovery transport failure
	answer   func(port int) dialAnswer // nil means every port completed a handshake
	ptr      map[string]ptrAnswer
	host     map[string]hostAnswer

	// Expectations.
	wantErr        bool
	wantVerdict    Verdict
	wantAll        Status         // status of every port; empty means StatusOpen
	wantStatus     map[int]Status // per-port overrides of wantAll
	wantSummary    []string       // substrings the summary must contain
	wantNotes      []string       // substrings the notes must contain
	wantNotNotes   []string       // substrings the notes must not contain
	wantIPRequests int            // discovery requests expected
}

func TestCheck(t *testing.T) {
	cases := []checkCase{
		{
			name:           "every port open with a forward-confirmed PTR",
			ipBody:         testIP,
			ptr:            map[string]ptrAnswer{testIP: {names: []string{"mail.example.com."}}},
			host:           map[string]hostAnswer{"mail.example.com": {addrs: []string{testIP}}},
			wantVerdict:    VerdictYes,
			wantSummary:    []string{"邮件端口：25 通", "PTR 有 · FCrDNS 一致", "可以搭邮局"},
			wantNotes:      []string{"公网 IPv4：203.0.113.7", "来源：https://api.ipify.org", "PTR：mail.example.com"},
			wantIPRequests: 1,
		},
		{
			name:   "25 refused and the rest open",
			ipBody: testIP,
			answer: func(port int) dialAnswer {
				if port == smtpPort {
					return dialAnswer{err: errRefused()}
				}
				return dialAnswer{conn: nopConn{}}
			},
			ptr:         map[string]ptrAnswer{testIP: {names: []string{"mail.example.com"}}},
			host:        map[string]hostAnswer{"mail.example.com": {addrs: []string{testIP}}},
			wantVerdict: VerdictYes,
			// A refusal proves the packet arrived, so it counts as reachable.
			wantStatus:     map[int]Status{smtpPort: StatusRefused},
			wantSummary:    []string{"邮件端口：25 通", "可以搭邮局"},
			wantNotes:      []string{"RST", "可达(未监听)"},
			wantNotNotes:   []string{"25 端口不通"},
			wantIPRequests: 1,
		},
		{
			name:   "25 blocked by the provider",
			ipBody: testIP,
			answer: func(port int) dialAnswer {
				if port == smtpPort {
					return dialAnswer{err: errDeadline()}
				}
				return dialAnswer{conn: nopConn{}}
			},
			ptr:            map[string]ptrAnswer{testIP: {names: []string{"mail.example.com"}}},
			host:           map[string]hostAnswer{"mail.example.com": {addrs: []string{testIP}}},
			wantVerdict:    VerdictNo,
			wantStatus:     map[int]Status{smtpPort: StatusBlocked},
			wantSummary:    []string{"25 不通", "不建议搭邮局（25 需解封）"},
			wantNotes:      []string{"默认封锁 25", "提交工单", "结论依据：25 端口不通"},
			wantIPRequests: 1,
		},
		{
			name:        "every port times out",
			ipBody:      testIP,
			answer:      func(int) dialAnswer { return dialAnswer{err: errDeadline()} },
			ptr:         map[string]ptrAnswer{testIP: {names: []string{"mail.example.com"}}},
			host:        map[string]hostAnswer{"mail.example.com": {addrs: []string{testIP}}},
			wantVerdict: VerdictNo,
			wantAll:     StatusBlocked,
			wantSummary: []string{"25 不通", "不建议搭邮局（25 需解封）"},
			// The hairpin caveat is what a "everything is filtered" reading needs.
			wantNotes:      []string{"NAT 回环"},
			wantIPRequests: 1,
		},
		{
			name:   "the whole verdict turns on 25, not on the other mail ports",
			ipBody: testIP,
			answer: func(port int) dialAnswer {
				if port == 465 || port == 587 || port == 993 {
					return dialAnswer{err: errDeadline()}
				}
				return dialAnswer{conn: nopConn{}}
			},
			ptr:            map[string]ptrAnswer{testIP: {names: []string{"mail.example.com"}}},
			host:           map[string]hostAnswer{"mail.example.com": {addrs: []string{testIP}}},
			wantVerdict:    VerdictYes,
			wantStatus:     map[int]Status{465: StatusBlocked, 587: StatusBlocked, 993: StatusBlocked},
			wantSummary:    []string{"可以搭邮局"},
			wantIPRequests: 1,
		},
		{
			name:           "PTR missing",
			ipBody:         testIP,
			ptr:            map[string]ptrAnswer{testIP: {}}, // an answer with no records
			wantVerdict:    VerdictNo,
			wantSummary:    []string{"25 通", "PTR 缺失", "不建议搭邮局（缺 PTR）"},
			wantNotes:      []string{"PTR 缺失", "rDNS/PTR", "结论依据：25 端口可达，但 PTR 缺失"},
			wantIPRequests: 1,
		},
		{
			name:   "PTR missing as NXDOMAIN",
			ipBody: testIP,
			ptr: map[string]ptrAnswer{testIP: {
				err: &net.DNSError{Err: "no such host", Name: testIP, IsNotFound: true},
			}},
			wantVerdict:    VerdictNo,
			wantSummary:    []string{"PTR 缺失", "不建议搭邮局（缺 PTR）"},
			wantNotes:      []string{"PTR 缺失"},
			wantIPRequests: 1,
		},
		{
			name:   "PTR exists but does not resolve back",
			ipBody: testIP,
			ptr:    map[string]ptrAnswer{testIP: {names: []string{"mail.example.com"}}},
			host:   map[string]hostAnswer{"mail.example.com": {addrs: []string{"198.51.100.9"}}},
			// 25 answers, so the failure under test is the FCrDNS one.
			wantVerdict:    VerdictNo,
			wantSummary:    []string{"PTR 有 · FCrDNS 不一致", "不建议搭邮局（FCrDNS 不一致）"},
			wantNotes:      []string{"FCrDNS 不一致", "结论依据：25 端口可达，PTR 存在但 FCrDNS 不一致"},
			wantIPRequests: 1,
		},
		{
			name:   "PTR lookup fails",
			ipBody: testIP,
			ptr: map[string]ptrAnswer{testIP: {
				err: errors.New("resolver unreachable"),
			}},
			wantVerdict:    VerdictUnknown,
			wantSummary:    []string{"PTR 无法确认", "无法确认"},
			wantNotes:      []string{"PTR 查询失败", "resolver unreachable"},
			wantIPRequests: 1,
		},
		{
			name:   "25 fails with a reason that is neither a refusal nor a deadline",
			ipBody: testIP,
			answer: func(port int) dialAnswer {
				if port == smtpPort {
					return dialAnswer{err: errors.New("network is unreachable")}
				}
				return dialAnswer{conn: nopConn{}}
			},
			ptr:            map[string]ptrAnswer{testIP: {names: []string{"mail.example.com"}}},
			host:           map[string]hostAnswer{"mail.example.com": {addrs: []string{testIP}}},
			wantVerdict:    VerdictUnknown,
			wantStatus:     map[int]Status{smtpPort: StatusError},
			wantSummary:    []string{"25 检测失败", "无法确认"},
			wantNotes:      []string{"25 端口探测出错", "network is unreachable"},
			wantIPRequests: 1,
		},
		{
			name:           "public IPv4 unreachable",
			ipErr:          errors.New("dial tcp 1.1.1.1:443: i/o timeout"),
			wantErr:        true,
			wantVerdict:    VerdictUnknown,
			wantAll:        StatusSkipped,
			wantSummary:    []string{"邮件端口：无法确认 · 公网 IP 未取到"},
			wantNotes:      []string{"公网 IPv4 未取到", "i/o timeout"},
			wantIPRequests: 1,
		},
		{
			name:           "discovery endpoint answers an error status",
			ipStatus:       http.StatusInternalServerError,
			wantErr:        true,
			wantVerdict:    VerdictUnknown,
			wantAll:        StatusSkipped,
			wantSummary:    []string{"无法确认"},
			wantNotes:      []string{"HTTP 500"},
			wantIPRequests: 1,
		},
		{
			name:           "discovery endpoint answers something that is not an address",
			ipBody:         "<html>blocked</html>",
			wantErr:        true,
			wantVerdict:    VerdictUnknown,
			wantAll:        StatusSkipped,
			wantNotes:      []string{"is not an IPv4 address"},
			wantIPRequests: 1,
		},
		{
			name:           "injected public IP skips discovery",
			publicIP:       testIP,
			ipBody:         "192.0.2.1", // must not be used
			ptr:            map[string]ptrAnswer{testIP: {names: []string{"mail.example.com"}}},
			host:           map[string]hostAnswer{"mail.example.com": {addrs: []string{"203.0.113.7"}}},
			wantVerdict:    VerdictYes,
			wantSummary:    []string{"可以搭邮局"},
			wantNotes:      []string{"来源：Options.PublicIP"},
			wantIPRequests: 0,
		},
		{
			name:        "injected public IP is not an address",
			publicIP:    "not-an-ip",
			wantErr:     true,
			wantVerdict: VerdictUnknown,
			wantAll:     StatusSkipped,
			wantNotes:   []string{"Options.PublicIP"},
		},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			client := &fakeHTTP{t: t, body: tc.ipBody, status: tc.ipStatus, err: tc.ipErr}
			answer := tc.answer
			if answer == nil {
				answer = func(int) dialAnswer { return dialAnswer{conn: nopConn{}} }
			}
			dialer := &fakeDialer{t: t, answer: answer}
			resolver := &fakeResolver{t: t, ptr: tc.ptr, host: tc.host}

			rep, err := Check(context.Background(), Options{
				PublicIP:    tc.publicIP,
				IPURL:       tc.ipURL,
				Client:      client,
				Dialer:      dialer,
				Resolver:    resolver,
				DialTimeout: 5 * time.Second,
				Timeout:     30 * time.Second,
			})

			if got := err != nil; got != tc.wantErr {
				t.Fatalf("Check error = %v, want error == %v", err, tc.wantErr)
			}
			if rep.Verdict != tc.wantVerdict {
				t.Errorf("verdict = %q, want %q", rep.Verdict, tc.wantVerdict)
			}

			// Every catalogue entry gets a row, in order, whether or not it was
			// dialled.
			if len(rep.Ports) != len(catalogue) {
				t.Fatalf("got %d port results, want %d", len(rep.Ports), len(catalogue))
			}
			for i, p := range rep.Ports {
				if p.Port.Number != catalogue[i].Number {
					t.Fatalf("port result %d = %d, want %d", i, p.Port.Number, catalogue[i].Number)
				}
				want := tc.wantAll
				if want == "" {
					want = StatusOpen
				}
				if o, ok := tc.wantStatus[p.Port.Number]; ok {
					want = o
				}
				if p.Status != want {
					t.Errorf("port %d status = %q, want %q (dial error %q)", p.Port.Number, p.Status, want, p.Error)
				}
			}

			// The probe list is what was dialled: every port on the public IP,
			// never on the loopback, and nothing at all without an address.
			dialed := dialer.addresses()
			if tc.wantAll == StatusSkipped {
				if len(dialed) != 0 {
					t.Errorf("dialled %v without a public IP", dialed)
				}
			} else if len(dialed) != len(catalogue) {
				t.Errorf("dialled %d addresses, want %d: %v", len(dialed), len(catalogue), dialed)
			}
			for _, addr := range dialed {
				if !strings.HasPrefix(addr, "tcp4|"+testIP+":") {
					t.Errorf("dialled %q, want every dial on %s", addr, testIP)
				}
			}

			if got := len(client.requests()); got != tc.wantIPRequests {
				t.Errorf("discovery requests = %d (%v), want %d", got, client.requests(), tc.wantIPRequests)
			}
			if tc.wantIPRequests > 0 && tc.ipURL == "" {
				if got := client.requests()[0]; got != DefaultIPURL {
					t.Errorf("discovery URL = %q, want the documented default %q", got, DefaultIPURL)
				}
			}

			summary := rep.Summary()
			for _, want := range tc.wantSummary {
				if !strings.Contains(summary, want) {
					t.Errorf("summary %q does not contain %q", summary, want)
				}
			}
			if strings.ContainsAny(summary, "\n\r") {
				t.Errorf("summary %q is not one line", summary)
			}
			notes := strings.Join(rep.Notes, "\n")
			for _, want := range tc.wantNotes {
				if !strings.Contains(notes, want) {
					t.Errorf("notes do not contain %q:\n%s", want, notes)
				}
			}
			for _, bad := range tc.wantNotNotes {
				if strings.Contains(notes, bad) {
					t.Errorf("notes unexpectedly contain %q:\n%s", bad, notes)
				}
			}
		})
	}
}

// TestResultShape pins the table the panel draws: three columns, one row per
// port, and the notes carrying the reverse DNS and the conclusion.
func TestResultShape(t *testing.T) {
	rep, err := Check(context.Background(), Options{
		PublicIP: testIP,
		Client:   &fakeHTTP{t: t},
		Dialer:   &fakeDialer{t: t, answer: func(int) dialAnswer { return dialAnswer{conn: nopConn{}} }},
		Resolver: &fakeResolver{
			t:    t,
			ptr:  map[string]ptrAnswer{testIP: {names: []string{"mail.example.com"}}},
			host: map[string]hostAnswer{"mail.example.com": {addrs: []string{testIP}}},
		},
	})
	if err != nil {
		t.Fatalf("Check: %v", err)
	}

	out := rep.Result()
	if want := []string{"端口", "用途", "状态"}; !equalStrings(out.Headers, want) {
		t.Fatalf("headers = %v, want %v", out.Headers, want)
	}
	if len(out.Rows) != len(catalogue) {
		t.Fatalf("got %d rows, want %d", len(out.Rows), len(catalogue))
	}
	for i, row := range out.Rows {
		if len(row) != len(out.Headers) {
			t.Errorf("row %d has %d cells, want %d: %v", i, len(row), len(out.Headers), row)
		}
		if row[0] != strconv.Itoa(catalogue[i].Number) {
			t.Errorf("row %d port cell = %q, want %q", i, row[0], strconv.Itoa(catalogue[i].Number))
		}
		if row[1] != catalogue[i].Purpose {
			t.Errorf("row %d purpose cell = %q, want %q", i, row[1], catalogue[i].Purpose)
		}
		if row[2] == "" {
			t.Errorf("row %d has an empty status cell", i)
		}
	}
	notes := strings.Join(out.Notes, "\n")
	for _, want := range []string{"PTR", "FCrDNS", "结论依据", "53/80/443", "透明代理", "无法确认"} {
		if !strings.Contains(notes, want) {
			t.Errorf("notes do not contain %q:\n%s", want, notes)
		}
	}
	if out.Summary == "" {
		t.Error("summary is empty")
	}
}

// TestPortsCatalogue pins the port list and which of them belong to a mailbox.
func TestPortsCatalogue(t *testing.T) {
	want := []Port{
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
	got := Ports()
	if len(got) != len(want) {
		t.Fatalf("got %d ports, want %d", len(got), len(want))
	}
	for i := range want {
		if got[i] != want[i] {
			t.Errorf("port %d = %+v, want %+v", i, got[i], want[i])
		}
	}
	// Ports returns a copy: a caller reordering the list must not reorder the
	// report.
	got[0].Number = 1
	if Ports()[0].Number != 25 {
		t.Error("Ports returned the catalogue itself, not a copy")
	}
}

// TestStatusVocabulary pins the states the verdict rules are written against.
func TestStatusVocabulary(t *testing.T) {
	cases := []struct {
		status    Status
		wantText  string
		reachable bool
	}{
		{StatusOpen, "开放", true},
		{StatusRefused, "可达(未监听)", true},
		{StatusBlocked, "超时", false},
		{StatusError, "错误", false},
		{StatusSkipped, "未检测", false},
	}
	for _, tc := range cases {
		if got := tc.status.Text(); got != tc.wantText {
			t.Errorf("%q text = %q, want %q", tc.status, got, tc.wantText)
		}
		if got := tc.status.Reachable(); got != tc.reachable {
			t.Errorf("%q reachable = %v, want %v", tc.status, got, tc.reachable)
		}
	}
}

// TestVerdictText pins the wording of the conclusion itself.
func TestVerdictText(t *testing.T) {
	cases := map[Verdict]string{
		VerdictYes:     "可以搭邮局",
		VerdictNo:      "不建议搭邮局",
		VerdictUnknown: "无法确认",
	}
	for v, want := range cases {
		if got := v.Text(); got != want {
			t.Errorf("verdict %q text = %q, want %q", v, got, want)
		}
	}
}

// TestToolEntry pins what the toolbox registry reads off this tool.
func TestToolEntry(t *testing.T) {
	tool := Tool()
	if tool.ID != "portcheck" {
		t.Errorf("id = %q, want portcheck", tool.ID)
	}
	// The mail ports are asked of this host's own public address, so the entry is
	// filed with the IP quality checks rather than with the reachability probes.
	if tool.Group != "ip" {
		t.Errorf("group = %q, want ip", tool.Group)
	}
	if tool.Run == nil {
		t.Error("Run is nil: the registry cannot run the tool")
	}
}

// TestClassify covers the dial outcomes a real dial can produce, including the
// platform errno for a refusal.
func TestClassify(t *testing.T) {
	cases := []struct {
		name string
		err  error
		want Status
	}{
		{"handshake completed", nil, StatusOpen},
		{"refused", errRefused(), StatusRefused},
		{"deadline", errDeadline(), StatusBlocked},
		{"context deadline", fmt.Errorf("dial: %w", context.DeadlineExceeded), StatusBlocked},
		{"other", errors.New("network is unreachable"), StatusError},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			if got := classify(tc.err); got != tc.want {
				t.Errorf("classify(%v) = %q, want %q", tc.err, got, tc.want)
			}
		})
	}
}

// TestParseIPv4 rejects anything that is not one IPv4 address, so a discovery
// endpoint cannot hand the probes an address they would dial blindly.
func TestParseIPv4(t *testing.T) {
	cases := []struct {
		in      string
		want    string
		wantErr bool
	}{
		{in: " 203.0.113.7\n", want: "203.0.113.7"},
		{in: "203.0.113.7", want: "203.0.113.7"},
		{in: "::ffff:203.0.113.7", want: "203.0.113.7"},
		{in: "2001:db8::1", wantErr: true},
		{in: "", wantErr: true},
		{in: "<html>", wantErr: true},
		{in: "203.0.113.7 1.2.3.4", wantErr: true},
	}
	for _, tc := range cases {
		got, err := parseIPv4(tc.in)
		if gotErr := err != nil; gotErr != tc.wantErr {
			t.Errorf("parseIPv4(%q) error = %v, want error == %v", tc.in, err, tc.wantErr)
			continue
		}
		if got != tc.want {
			t.Errorf("parseIPv4(%q) = %q, want %q", tc.in, got, tc.want)
		}
	}
}

func equalStrings(a, b []string) bool {
	if len(a) != len(b) {
		return false
	}
	for i := range a {
		if a[i] != b[i] {
			return false
		}
	}
	return true
}
