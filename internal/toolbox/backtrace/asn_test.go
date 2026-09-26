package backtrace

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"strings"
	"sync"
	"testing"
	"time"
)

// fakeHTTP answers from a script and remembers every request, so the batch
// client is exercised without a network.
type fakeHTTP struct {
	answer func(req *http.Request, body []byte) (*http.Response, error)

	mu     sync.Mutex
	calls  []string
	bodies [][]byte
}

func (f *fakeHTTP) Do(req *http.Request) (*http.Response, error) {
	var body []byte
	if req.Body != nil {
		body, _ = io.ReadAll(req.Body)
		req.Body.Close()
	}
	f.mu.Lock()
	f.calls = append(f.calls, req.Method+" "+req.URL.String())
	f.bodies = append(f.bodies, body)
	f.mu.Unlock()
	return f.answer(req, body)
}

// httpResponse builds a canned response with a body.
func httpResponse(status int, body string) *http.Response {
	return &http.Response{
		StatusCode: status,
		Status:     fmt.Sprintf("%d %s", status, http.StatusText(status)),
		Body:       io.NopCloser(strings.NewReader(body)),
		Header:     http.Header{},
	}
}

// successClient answers every address with one carrier's AS, echoing the address
// back the way ip-api does.
func successClient(t *testing.T, asn, isp string) *fakeHTTP {
	t.Helper()
	return &fakeHTTP{answer: func(_ *http.Request, body []byte) (*http.Response, error) {
		var ips []string
		if err := json.Unmarshal(body, &ips); err != nil {
			t.Errorf("request body is not an address array: %v", err)
			return httpResponse(http.StatusBadRequest, "[]"), nil
		}
		answers := make([]apiAnswer, 0, len(ips))
		for _, ip := range ips {
			answers = append(answers, apiAnswer{Status: "success", CountryCode: "cn", ISP: isp, AS: asn + " " + isp, ASName: isp, Query: ip})
		}
		data, err := json.Marshal(answers)
		if err != nil {
			t.Errorf("marshal answers: %v", err)
			return httpResponse(http.StatusInternalServerError, "[]"), nil
		}
		return httpResponse(http.StatusOK, string(data)), nil
	}}
}

// testAddrs builds n distinct addresses from the TEST-NET-3 range.
func testAddrs(n int) []net.IP {
	out := make([]net.IP, 0, n)
	for i := 1; i <= n; i++ {
		out = append(out, net.ParseIP(fmt.Sprintf("203.0.113.%d", i)))
	}
	return out
}

func TestAPILookupBatches(t *testing.T) {
	client := successClient(t, "AS4134", "CHINANET-BACKBONE")
	l := newAPILookup(client, nil)
	l.minInterval = 0 // pacing is exercised on its own below

	ips := testAddrs(250)
	facts, err := l.Lookup(context.Background(), ips)
	if err != nil {
		t.Fatalf("Lookup: %v", err)
	}
	if len(facts) != len(ips) {
		t.Fatalf("facts = %d, want one per address (%d)", len(facts), len(ips))
	}
	var sizes []int
	for _, body := range client.bodies {
		var asked []string
		if err := json.Unmarshal(body, &asked); err != nil {
			t.Fatalf("request body: %v", err)
		}
		sizes = append(sizes, len(asked))
	}
	if fmt.Sprint(sizes) != "[100 100 50]" {
		t.Errorf("batch sizes = %v, want [100 100 50] (the endpoint's cap is 100)", sizes)
	}
	for _, call := range client.calls {
		if !strings.HasPrefix(call, "POST http://ip-api.com/batch") {
			t.Errorf("call = %q, want a POST to the batch endpoint", call)
		}
	}
	if !strings.Contains(client.calls[0], "fields=status") {
		t.Errorf("call = %q, want the fields parameter that trims the answer", client.calls[0])
	}
	f, ok := facts["219.141.140.10"]
	if ok {
		t.Errorf("an address that was never asked about came back: %v", f)
	}
	if f := facts["203.0.113.1"]; !f.Known || f.ASN != 4134 || f.Country != "CN" {
		t.Errorf("fact = %+v, want a known CN AS4134 answer", f)
	}
}

func TestAPILookupPacesItsCalls(t *testing.T) {
	clock := newTestClock()
	var waits []time.Duration
	l := newAPILookup(successClient(t, "AS4134", "CHINANET-BACKBONE"), clock.now)
	l.sleep = func(_ context.Context, d time.Duration) error {
		waits = append(waits, d)
		clock.add(d)
		return nil
	}

	// 150 addresses need two batches, so the second call waits.
	if _, err := l.Lookup(context.Background(), testAddrs(150)); err != nil {
		t.Fatalf("Lookup: %v", err)
	}
	if len(waits) != 1 || waits[0] != apiMinInterval {
		t.Fatalf("waits = %v, want one wait of %v (45 requests a minute)", waits, apiMinInterval)
	}
	if apiMinInterval < time.Minute/45 {
		t.Errorf("apiMinInterval = %v, which is over the free tier's 45 requests a minute", apiMinInterval)
	}
}

func TestAPILookupDegradesInsteadOfFailing(t *testing.T) {
	tests := []struct {
		name       string
		status     int
		body       string
		clientErr  error
		wantReason string
	}{
		{name: "rate limited", status: http.StatusTooManyRequests, body: "Too many requests", wantReason: "限流"},
		{name: "server error", status: http.StatusBadGateway, wantReason: "HTTP 502"},
		{name: "nothing answered", clientErr: errors.New("dial tcp 208.95.112.1:80: i/o timeout"), wantReason: "ip-api 查询失败"},
		{name: "not json", status: http.StatusOK, body: "<html>nope</html>", wantReason: "解析 ip-api 响应失败"},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			client := &fakeHTTP{answer: func(*http.Request, []byte) (*http.Response, error) {
				if tt.clientErr != nil {
					return nil, tt.clientErr
				}
				return httpResponse(tt.status, tt.body), nil
			}}
			l := newAPILookup(client, nil)
			l.minInterval = 0

			facts, err := l.Lookup(context.Background(), testAddrs(2))
			if err != nil {
				t.Fatalf("Lookup returned %v, want the failure folded into the facts", err)
			}
			if len(facts) != 2 {
				t.Fatalf("facts = %d, want 2", len(facts))
			}
			for ip, f := range facts {
				if f.Known {
					t.Errorf("%s came back known, want unknown", ip)
				}
				if !strings.Contains(f.Reason, tt.wantReason) {
					t.Errorf("%s reason = %q, want it to contain %q", ip, f.Reason, tt.wantReason)
				}
			}
		})
	}
}

func TestAPILookupReadsTheAnswer(t *testing.T) {
	body := `[
	  {"status":"fail","message":"reserved range","query":"10.0.0.1"},
	  {"status":"success","countryCode":"CN","isp":"Chinanet","org":"Chinanet",
	   "as":"AS4134 CHINANET-BACKBONE","asname":"CHINANET-BACKBONE","query":"219.141.140.10"}
	]`
	client := &fakeHTTP{answer: func(*http.Request, []byte) (*http.Response, error) {
		return httpResponse(http.StatusOK, body), nil
	}}
	l := newAPILookup(client, nil)
	l.minInterval = 0

	facts, err := l.Lookup(context.Background(), []net.IP{net.ParseIP("10.0.0.1"), net.ParseIP("219.141.140.10")})
	if err != nil {
		t.Fatalf("Lookup: %v", err)
	}
	if f := facts["10.0.0.1"]; f.Known || f.Reason != "reserved range" {
		t.Errorf("private address = %+v, want the endpoint's own reason", f)
	}
	f := facts["219.141.140.10"]
	if !f.Known || f.ASN != 4134 || f.Country != "CN" || f.label() != "AS4134" {
		t.Errorf("public address = %+v, want a known CN AS4134 answer", f)
	}
}

func TestAPILookupPlacesAnAnswerWithoutQueryEcho(t *testing.T) {
	// The endpoint answers in request order; an entry missing its own address can
	// still be placed, and an address with no entry at all is reported as such.
	body := `[{"status":"success","countryCode":"CN","as":"AS4134 CHINANET"}]`
	client := &fakeHTTP{answer: func(*http.Request, []byte) (*http.Response, error) {
		return httpResponse(http.StatusOK, body), nil
	}}
	l := newAPILookup(client, nil)
	l.minInterval = 0

	facts, err := l.Lookup(context.Background(), []net.IP{net.ParseIP("1.1.1.1"), net.ParseIP("2.2.2.2")})
	if err != nil {
		t.Fatalf("Lookup: %v", err)
	}
	if f := facts["1.1.1.1"]; !f.Known || f.ASN != 4134 {
		t.Errorf("first address = %+v, want the answer placed by position", f)
	}
	if f := facts["2.2.2.2"]; f.Known || !strings.Contains(f.Reason, "未返回") {
		t.Errorf("second address = %+v, want an unknown fact naming the gap", f)
	}
}

func TestAPILookupStopsWhenTheRunIsCancelled(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	l := newAPILookup(successClient(t, "AS4134", "CHINANET"), nil)

	// Two batches: the first is sent, then the pacing wait before the second
	// notices the cancelled context instead of sleeping out the interval.
	facts, err := l.Lookup(ctx, testAddrs(150))
	if !errors.Is(err, context.Canceled) {
		t.Fatalf("Lookup error = %v, want context.Canceled", err)
	}
	if len(facts) != 100 {
		t.Errorf("facts = %d, want the 100 the first batch answered for", len(facts))
	}
}

func TestAPILookupWithNothingToAsk(t *testing.T) {
	client := &fakeHTTP{answer: func(*http.Request, []byte) (*http.Response, error) {
		t.Error("no request may be sent when there is nothing to ask about")
		return httpResponse(http.StatusOK, "[]"), nil
	}}
	facts, err := newAPILookup(client, nil).Lookup(context.Background(), []net.IP{nil})
	if err != nil {
		t.Fatalf("Lookup: %v", err)
	}
	if len(facts) != 0 || len(client.calls) != 0 {
		t.Errorf("facts = %v, calls = %v, want nothing", facts, client.calls)
	}
}

func TestDedupeAddrs(t *testing.T) {
	got := dedupeAddrs([]net.IP{
		net.ParseIP("203.0.113.9"),
		nil,
		net.ParseIP("192.0.2.1"),
		net.ParseIP("203.0.113.9"),
	})
	want := []string{"192.0.2.1", "203.0.113.9"}
	if fmt.Sprint(got) != fmt.Sprint(want) {
		t.Errorf("dedupeAddrs = %v, want %v (sorted, without duplicates or nils)", got, want)
	}
}

func TestFactLabelTrimsALongProviderName(t *testing.T) {
	tests := []struct {
		name string
		fact Fact
		want string
	}{
		{"an AS number is always short", Fact{ASN: 4538}, "AS4538"},
		{"a name that fits is kept", Fact{ISP: "Small Regional ISP"}, "Small Regional ISP"},
		{"a long name is trimmed", Fact{ISP: strings.Repeat("a", 40)}, strings.Repeat("a", maxBackboneLen-1) + "…"},
		{"a long CJK name is trimmed by rune", Fact{ISP: strings.Repeat("测", 40)}, strings.Repeat("测", maxBackboneLen-1) + "…"},
		{"the org stands in when there is no ISP", Fact{Org: "Example Org"}, "Example Org"},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			if got := tt.fact.label(); got != tt.want {
				t.Errorf("label = %q, want %q", got, tt.want)
			}
		})
	}
}

func TestParseASN(t *testing.T) {
	tests := []struct {
		in   string
		want int
	}{
		{"AS4134 CHINANET-BACKBONE", 4134},
		{"as4809 CN2", 4809},
		{"AS58807 CMIN2", 58807},
		{"AS0000000", 0},
		{"", 0},
		{"no number here", 0},
		{"AS", 0},
		{"AS99999999999999999999", 0},
	}
	for _, tt := range tests {
		t.Run(tt.in, func(t *testing.T) {
			if got := parseASN(tt.in); got != tt.want {
				t.Errorf("parseASN(%q) = %d, want %d", tt.in, got, tt.want)
			}
		})
	}
}

// TestNameFactReadsTheSpellingsRealHostsReturn pins the readings that a tidier
// marker list got wrong on a real machine: three Chinese paths were reported as
// 国际多线 because ip-api named them "UNICOM", "CNCGROUP-SZ" and "Chinatelecom
// Next Carrying Network backbone" rather than "China Unicom"/"China Telecom".
func TestNameFactReadsTheSpellingsRealHostsReturn(t *testing.T) {
	cn := func(asn int, isp, org, asname string) Fact {
		return Fact{Country: "CN", ASN: asn, ISP: isp, Org: org, ASName: asname, Known: true}
	}
	tests := []struct {
		name    string
		fact    Fact
		carrier Carrier
		backbon string
	}{
		{
			name: "a Beijing Unicom path whose hop is named only UNICOM",
			fact: cn(0, "UNICOM", "", "UNICOM"), carrier: CarrierUnicom,
		},
		{
			name: "a Guangzhou Unicom path on CNCGROUP-SZ",
			fact: cn(0, "CNCGROUP-SZ", "", "CNCGROUP-SZ"), carrier: CarrierUnicom,
		},
		{
			name: "a Shenzhen Unicom AS by number alone",
			fact: cn(17623, "", "", ""), carrier: CarrierUnicom, backbon: "4837",
		},
		{
			name: "a CN2 path named Chinatelecom Next Carrying Network",
			fact: cn(0, "Chinatelecom Next Carrying Network backbone", "", ""), carrier: CarrierTelecom,
		},
		{
			name: "a CN2 hop by AS number alone",
			fact: cn(4809, "", "", ""), carrier: CarrierTelecom, backbon: "CN2",
		},
		{
			name: "a mobile network named CMI",
			fact: cn(0, "CMI", "", "CMI"), carrier: CarrierMobile,
		},
	}
	for _, tc := range tests {
		got := nameFact(tc.fact, true)
		if !got.known || got.carrier != tc.carrier {
			t.Errorf("%s: carrier = %q (known %v), want %q", tc.name, got.carrier, got.known, tc.carrier)
		}
		if tc.backbon != "" && got.backbone != tc.backbon {
			t.Errorf("%s: backbone = %q, want %q", tc.name, got.backbone, tc.backbon)
		}
	}
}

func TestCarrierLabels(t *testing.T) {
	tests := map[Carrier]string{
		CarrierTelecom:       "电信",
		CarrierUnicom:        "联通",
		CarrierMobile:        "移动",
		CarrierInternational: "国际多线",
		CarrierUnknown:       "无法判定",
		Carrier("nonsense"):  "无法判定",
	}
	for c, want := range tests {
		if got := c.Label(); got != want {
			t.Errorf("Carrier(%q).Label() = %q, want %q", c, got, want)
		}
	}
}

func TestNameFact(t *testing.T) {
	cn := func(asn int, isp, asname string) Fact {
		return Fact{Country: "CN", ASN: asn, ISP: isp, ASName: asname, Known: true}
	}
	tests := []struct {
		name         string
		fact         Fact
		have         bool
		known        bool
		cn           bool
		carrier      Carrier
		backbone     string
		reasonHas    string
		evidenceHas  string
		wantEvidence bool
	}{
		{
			name: "telecom 163", fact: cn(4134, "Chinanet", "CHINANET-BACKBONE"), have: true,
			known: true, cn: true, carrier: CarrierTelecom, backbone: "163",
		},
		{
			name: "telecom CN2", fact: cn(4809, "China Telecom", "CN2"), have: true,
			known: true, cn: true, carrier: CarrierTelecom, backbone: "CN2",
		},
		{
			name: "unicom 9929", fact: cn(9929, "China Unicom", "CUII"), have: true,
			known: true, cn: true, carrier: CarrierUnicom, backbone: "9929",
		},
		{
			name: "mobile CMIN2", fact: cn(58807, "China Mobile", "CMIN2"), have: true,
			known: true, cn: true, carrier: CarrierMobile, backbone: "CMIN2",
		},
		{
			name: "a regional telecom AS named only by its ISP",
			fact: cn(0, "China Telecom Beijing", ""), have: true,
			known: true, cn: true, carrier: CarrierTelecom,
		},
		{
			name: "a mainland network that is not one of the three",
			fact: cn(4538, "China Education and Research Network Center", "CHINA EDUCATION AND RESEARCH NETWORK"), have: true,
			known: true, cn: true, carrier: CarrierInternational, backbone: "AS4538",
			wantEvidence: true, evidenceHas: "AS4538",
		},
		{
			name: "a mainland address with no ASN and no operator name",
			fact: Fact{Country: "CN", Known: true}, have: true,
			known: false, cn: true, reasonHas: "没有 ISP/ASN",
		},
		{
			name: "outside the mainland", fact: Fact{Country: "JP", ISP: "IIJ", ASN: 2497, Known: true}, have: true,
			known: false, cn: false, reasonHas: "大陆之外",
		},
		{
			name: "hong kong is not the mainland",
			fact: Fact{Country: "HK", ISP: "China Mobile Hong Kong", ASN: 58453, Known: true}, have: true,
			known: false, cn: false, reasonHas: "大陆之外",
		},
		{
			name: "the lookup said fail", fact: Fact{Reason: "reserved range"}, have: true,
			known: false, reasonHas: "reserved range",
		},
		{
			name: "the lookup has nothing at all", fact: Fact{}, have: false,
			known: false, reasonHas: "没有返回",
		},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got := nameFact(tt.fact, tt.have)
			if got.known != tt.known || got.cn != tt.cn {
				t.Fatalf("nameFact = %+v, want known=%v cn=%v", got, tt.known, tt.cn)
			}
			if got.carrier != tt.carrier || got.backbone != tt.backbone {
				t.Errorf("carrier = %q/%q, want %q/%q", got.carrier, got.backbone, tt.carrier, tt.backbone)
			}
			if tt.reasonHas != "" && !strings.Contains(got.reason, tt.reasonHas) {
				t.Errorf("reason = %q, want it to contain %q", got.reason, tt.reasonHas)
			}
			if tt.wantEvidence && !strings.Contains(got.evidence, tt.evidenceHas) {
				t.Errorf("evidence = %q, want it to contain %q", got.evidence, tt.evidenceHas)
			}
		})
	}
}
