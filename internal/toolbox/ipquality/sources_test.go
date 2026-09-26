package ipquality

import (
	"reflect"
	"strings"
	"testing"
)

// sourceByName returns a catalogue entry, so a test drives the same url and parse the
// checker does.
func sourceByName(t *testing.T, name string) source {
	t.Helper()
	for _, s := range catalogue {
		if s.name == name {
			return s
		}
	}
	t.Fatalf("database %q is not in the catalogue", name)
	return source{}
}

func TestCatalogueIsWellFormed(t *testing.T) {
	if len(catalogue) == 0 {
		t.Fatal("the catalogue is empty")
	}
	seen := make(map[string]bool, len(catalogue))
	for _, s := range catalogue {
		if s.name == "" {
			t.Errorf("a catalogue entry has no name: %+v", s)
			continue
		}
		if seen[s.name] {
			t.Errorf("duplicate database name %q", s.name)
		}
		seen[s.name] = true
		if s.url == nil || s.parse == nil {
			t.Errorf("database %q has no url or no parser", s.name)
			continue
		}
		url := s.url(testIP)
		if !strings.Contains(url, testIP) {
			t.Errorf("database %q builds %q, which does not carry the address", s.name, url)
		}
		if !strings.HasPrefix(url, "https://") && !strings.HasPrefix(url, "http://") {
			t.Errorf("database %q builds %q, which is not an absolute URL", s.name, url)
		}
	}
}

// TestCannedBodiesParse is the guard on the recorded shapes: every canned answer must be
// read without a failure and carry the fields the catalogue claims for that database.
func TestCannedBodiesParse(t *testing.T) {
	for _, s := range catalogue {
		t.Run(s.name, func(t *testing.T) {
			body, ok := canned[s.name]
			if !ok {
				t.Fatalf("no canned answer for %q", s.name)
			}
			got := s.parse([]byte(body))
			if got.Fail != nil {
				t.Fatalf("parse failed: %s", got.Fail.Text())
			}
			if len(got.Missing) > 0 {
				t.Errorf("the canned answer is missing %v", got.Missing)
			}
			if got.Country == "" || got.City == "" {
				t.Errorf("country/city not read: %+v", got)
			}
			if s.name == "db-ip.com" {
				// db-ip's free answer is geography only: an ASN here would mean
				// the parser invented one.
				if got.ASN != "" || got.ISP != "" {
					t.Errorf("db-ip read fields it does not report: %+v", got)
				}
			} else if got.ASN != "AS64500" {
				t.Errorf("ASN = %q, want AS64500", got.ASN)
			}
		})
	}
}

// TestParsers covers the shapes each database can answer with, including the ones that
// are not an answer at all.
func TestParsers(t *testing.T) {
	const (
		ipAPI  = "ip-api.com"
		ipInfo = "ipinfo.io"
	)
	cases := []struct {
		name string
		src  string
		body string
		// want fields: only the ones a case cares about are compared.
		country    string
		city       string
		asn        string
		isp        string
		kind       Kind
		claim      string
		flags      []string
		flagsSet   bool
		risk       string
		missing    []string
		fail       FailReason
		failHas    string
		wantNoFail bool
	}{
		{
			name: "ip-api hosting is a datacenter",
			src:  ipAPI,
			body: `{"status":"success","countryCode":"DE","country":"Germany","city":"Frankfurt",` +
				`"isp":"Example Cloud GmbH","org":"Example Cloud","as":"AS64501 Example Cloud GmbH",` +
				`"proxy":false,"hosting":true,"mobile":false}`,
			country: "DE", city: "Frankfurt", asn: "AS64501", isp: "Example Cloud GmbH",
			kind: KindIDC, claim: "hosting=true", flags: []string{FlagHosting}, flagsSet: true,
			wantNoFail: true,
		},
		{
			name: "ip-api mobile beats hosting",
			src:  ipAPI,
			body: `{"status":"success","countryCode":"US","city":"Denver","isp":"Example Wireless",` +
				`"as":"AS64502 Example Wireless","proxy":true,"hosting":true,"mobile":true}`,
			country: "US", city: "Denver", asn: "AS64502", isp: "Example Wireless",
			kind: KindMobile, claim: "mobile=true",
			flags: []string{FlagProxy, FlagHosting, FlagMobile}, flagsSet: true,
			wantNoFail: true,
		},
		{
			name: "ip-api without a hosting or mobile flag claims no kind",
			src:  ipAPI,
			body: `{"status":"success","countryCode":"FR","city":"Paris","isp":"Example Telecom",` +
				`"as":"AS64503 Example Telecom","proxy":false,"hosting":false,"mobile":false}`,
			country: "FR", city: "Paris", asn: "AS64503", isp: "Example Telecom",
			kind: "", flags: nil, flagsSet: true, wantNoFail: true,
		},
		{
			name: "ip-api answers a reserved address with a fail status",
			src:  ipAPI,
			body: `{"status":"fail","message":"reserved range","query":"203.0.113.7"}`,
			fail: FailRefused, failHas: "reserved range",
		},
		{
			name: "ip-api answer without an ASN is a missing field, not a failure",
			src:  ipAPI,
			body: `{"status":"success","countryCode":"NL","city":"Amsterdam","isp":"Example BV",` +
				`"proxy":false,"hosting":false,"mobile":false}`,
			country: "NL", city: "Amsterdam", isp: "Example BV", flagsSet: true,
			missing: []string{"asn"}, wantNoFail: true,
		},
		{
			name: "ipinfo hosting type",
			src:  ipInfo,
			body: `{"data":{"city":"Singapore","country":"SG","org":"AS64504 Example Pte Ltd",` +
				`"asn":{"asn":"AS64504","name":"Example Pte Ltd","type":"hosting"},` +
				`"company":{"name":"Example Pte Ltd","type":"hosting"},` +
				`"privacy":{"vpn":false,"proxy":false,"tor":false,"relay":false,"hosting":true},` +
				`"is_mobile":false}}`,
			country: "SG", city: "Singapore", asn: "AS64504", isp: "Example Pte Ltd",
			kind: KindIDC, claim: "type=hosting", flags: []string{FlagHosting}, flagsSet: true,
			wantNoFail: true,
		},
		{
			name: "ipinfo business type",
			src:  ipInfo,
			body: `{"data":{"city":"Osaka","country":"JP","asn":{"asn":"AS64505","type":"business"},` +
				`"company":{"name":"Example Corp","type":"business"},` +
				`"privacy":{"hosting":false},"is_mobile":false}}`,
			country: "JP", city: "Osaka", asn: "AS64505", isp: "Example Corp",
			kind: KindBusiness, claim: "company.type=business", flagsSet: true, wantNoFail: true,
		},
		{
			name: "ipinfo isp type is a residential line",
			src:  ipInfo,
			body: `{"data":{"city":"Lyon","country":"FR","asn":{"asn":"AS64506","type":"isp"},` +
				`"company":{"name":"Example Telecom","type":"isp"},` +
				`"privacy":{"hosting":false},"is_mobile":false}}`,
			country: "FR", city: "Lyon", asn: "AS64506", isp: "Example Telecom",
			kind: KindHome, claim: "type=isp", flagsSet: true, wantNoFail: true,
		},
		{
			name: "ipinfo mobile wins and names the VPN service",
			src:  ipInfo,
			body: `{"data":{"city":"Berlin","country":"DE","asn":{"asn":"AS64507","type":"hosting"},` +
				`"company":{"name":"Example Mobile","type":"hosting"},` +
				`"privacy":{"vpn":true,"tor":true,"hosting":false,"service":"ExampleVPN"},` +
				`"is_mobile":true,"is_anycast":true}}`,
			country: "DE", city: "Berlin", asn: "AS64507", isp: "Example Mobile",
			kind: KindMobile, claim: "is_mobile=true",
			flags: []string{FlagVPN, FlagTor, FlagMobile, FlagAnycast}, flagsSet: true,
			risk: "VPN 服务 ExampleVPN", wantNoFail: true,
		},
		{
			name:       "ipinfo answer with no data at all reports every field as missing",
			src:        ipInfo,
			body:       `{"input":"203.0.113.7","data":{}}`,
			flagsSet:   true,
			missing:    []string{"country", "city", "asn", "isp"},
			wantNoFail: true,
		},
		{
			name: "ipapi.is reports a bogon flag and no kind",
			src:  "ipapi.is",
			body: `{"ip":"203.0.113.7","is_bogon":true,"company":"Example Hosting LLC",` +
				`"asn":"AS64500 Example Hosting LLC","city":"Los Angeles","country":"United States"}`,
			country: "United States", city: "Los Angeles", asn: "AS64500", isp: "Example Hosting LLC",
			flags: []string{FlagBogon}, flagsSet: true, wantNoFail: true,
		},
		{
			name: "ipwho.is reports a refusal as a success=false body",
			src:  "ipwho.is",
			body: `{"ip":"203.0.113.7","success":false,"message":"Reserved range"}`,
			fail: FailRefused, failHas: "Reserved range",
		},
		{
			name: "ipwho.is normal answer",
			src:  "ipwho.is",
			body: `{"success":true,"country":"Australia","country_code":"AU","city":"Sydney",` +
				`"connection":{"asn":64508,"org":"Example Pty","isp":"Example Broadband"}}`,
			country: "AU", city: "Sydney", asn: "AS64508", isp: "Example Broadband", wantNoFail: true,
		},
		{
			name: "ipwho.is answer with a null asn",
			src:  "ipwho.is",
			body: `{"success":true,"country":"Australia","country_code":"AU","city":"Sydney",` +
				`"connection":{"asn":null,"org":"Example Pty"}}`,
			country: "AU", city: "Sydney", isp: "Example Pty", missing: []string{"asn"}, wantNoFail: true,
		},
		{
			name: "ip.sb normal answer",
			src:  "ip.sb",
			body: `{"region":"New South Wales","organization":"Example Pty","isp":"Example Pty",` +
				`"city":"Sydney","asn_organization":"Example Pty","asn":64508,` +
				`"country":"Australia","country_code":"AU"}`,
			country: "AU", city: "Sydney", asn: "AS64508", isp: "Example Pty", wantNoFail: true,
		},
		{
			name: "ip2location proxy flag",
			src:  "ip2location.io",
			body: `{"country_code":"SG","country_name":"Singapore","city_name":"Singapore",` +
				`"asn":"64509","as":"Example Proxy Pte","is_proxy":true,` +
				`"message":"Limit to 1,000 queries per day."}`,
			country: "SG", city: "Singapore", asn: "AS64509", isp: "Example Proxy Pte",
			flags: []string{FlagProxy}, flagsSet: true, wantNoFail: true,
		},
		{
			name: "ipwhois.app normal answer",
			src:  "ipwhois.app",
			body: `{"success":true,"country_code":"GB","city":"London","asn":"AS64510",` +
				`"org":"Example Ltd","isp":"Example Ltd"}`,
			country: "GB", city: "London", asn: "AS64510", isp: "Example Ltd", wantNoFail: true,
		},
		{
			name: "ipwhois.app refusal",
			src:  "ipwhois.app",
			body: `{"success":false,"message":"invalid IP address"}`,
			fail: FailRefused, failHas: "invalid IP address",
		},
		{
			name:    "db-ip answers geography only and promises no more",
			src:     "db-ip.com",
			body:    `{"countryCode":"US","countryName":"United States","city":"Los Angeles"}`,
			country: "US", city: "Los Angeles", wantNoFail: true,
		},
		{
			name:    "db-ip without a city reports the missing field",
			src:     "db-ip.com",
			body:    `{"countryCode":"US","countryName":"United States"}`,
			country: "US", missing: []string{"city"}, wantNoFail: true,
		},
		{
			name: "ipapi.co rate limit arrives as a 200 body",
			src:  "ipapi.co",
			body: `{"error":true,"reason":"RateLimited","message":"Limit exceeded"}`,
			fail: FailRateLimit, failHas: "RateLimited",
		},
		{
			name: "ipapi.co refusal",
			src:  "ipapi.co",
			body: `{"error":true,"reason":"Invalid IP Address"}`,
			fail: FailRefused, failHas: "Invalid IP Address",
		},
		{
			name: "a block page is a parse failure, not an answer",
			src:  ipAPI,
			body: "<html><body>403 Forbidden</body></html>",
			fail: FailParse,
		},
		{
			name: "an empty body is a parse failure",
			src:  ipAPI,
			body: "   ",
			fail: FailParse, failHas: "响应为空",
		},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			s := sourceByName(t, tc.src)
			got := s.parse([]byte(tc.body))
			if tc.fail != "" {
				if got.Fail == nil {
					t.Fatalf("no failure, got %+v", got)
				}
				if got.Fail.Reason != tc.fail {
					t.Errorf("reason = %q, want %q", got.Fail.Reason, tc.fail)
				}
				if tc.failHas != "" && !strings.Contains(got.Fail.Text(), tc.failHas) {
					t.Errorf("failure text %q does not carry %q", got.Fail.Text(), tc.failHas)
				}
				if got.Country != "" || got.ASN != "" || got.ISP != "" {
					t.Errorf("a failed answer carried values: %+v", got)
				}
				return
			}
			if got.Fail != nil {
				t.Fatalf("unexpected failure: %s", got.Fail.Text())
			}
			if got.Country != tc.country {
				t.Errorf("country = %q, want %q", got.Country, tc.country)
			}
			if got.City != tc.city {
				t.Errorf("city = %q, want %q", got.City, tc.city)
			}
			if got.ASN != tc.asn {
				t.Errorf("asn = %q, want %q", got.ASN, tc.asn)
			}
			if got.ISP != tc.isp {
				t.Errorf("isp = %q, want %q", got.ISP, tc.isp)
			}
			if got.Kind != tc.kind {
				t.Errorf("kind = %q, want %q", got.Kind, tc.kind)
			}
			if tc.kind != "" && got.KindClaim != tc.claim {
				t.Errorf("claim = %q, want %q", got.KindClaim, tc.claim)
			}
			if !reflect.DeepEqual(got.Flags, tc.flags) {
				t.Errorf("flags = %v, want %v", got.Flags, tc.flags)
			}
			if tc.flagsSet && !got.FlagsKnown {
				t.Error("the database answered the flag question but FlagsKnown is false")
			}
			if got.Risk != tc.risk {
				t.Errorf("risk = %q, want %q", got.Risk, tc.risk)
			}
			if !reflect.DeepEqual(got.Missing, tc.missing) {
				t.Errorf("missing = %v, want %v", got.Missing, tc.missing)
			}
		})
	}
}

func TestASNOf(t *testing.T) {
	cases := []struct {
		in   string
		want string
	}{
		{"AS64500 Example Hosting LLC", "AS64500"},
		{"as64500 Something", "AS64500"},
		{"64500", "AS64500"},
		{"AS64500", "AS64500"},
		{"Example Hosting LLC", ""},
		{"", ""},
		{"   ", ""},
	}
	for _, tc := range cases {
		if got := asnOf(tc.in); got != tc.want {
			t.Errorf("asnOf(%q) = %q, want %q", tc.in, got, tc.want)
		}
	}
}

func TestASNOfInt(t *testing.T) {
	n := int64(64500)
	cases := []struct {
		in   *int64
		want string
	}{
		{&n, "AS64500"},
		{nil, ""},
		{new(int64), ""},
	}
	for _, tc := range cases {
		if got := asnOfInt(tc.in); got != tc.want {
			t.Errorf("asnOfInt(%v) = %q, want %q", tc.in, got, tc.want)
		}
	}
}

func TestKindLabel(t *testing.T) {
	cases := map[Kind]string{
		KindIDC:      "机房",
		KindHome:     "家宽",
		KindBusiness: "商宽",
		KindMobile:   "移动网络",
		KindMixed:    "不一致",
		KindUnknown:  "未知",
		"":           "未知",
	}
	for kind, want := range cases {
		if got := kind.Label(); got != want {
			t.Errorf("Kind(%q).Label() = %q, want %q", kind, got, want)
		}
	}
}

// TestVerdict is the rule that matters for honesty: a database that said nothing must not
// be read as agreement, and two databases that disagree must not be averaged.
func TestVerdict(t *testing.T) {
	cases := []struct {
		name  string
		basis []Basis
		want  Kind
	}{
		{name: "no claims", want: KindUnknown},
		{
			name:  "one claim",
			basis: []Basis{{Source: "ip-api.com", Kind: KindIDC}},
			want:  KindIDC,
		},
		{
			name: "two agreeing claims",
			basis: []Basis{
				{Source: "ip-api.com", Kind: KindIDC},
				{Source: "ipinfo.io", Kind: KindIDC},
			},
			want: KindIDC,
		},
		{
			name: "two disagreeing claims",
			basis: []Basis{
				{Source: "ip-api.com", Kind: KindMobile},
				{Source: "ipinfo.io", Kind: KindIDC},
			},
			want: KindMixed,
		},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			if got := verdict(tc.basis); got != tc.want {
				t.Errorf("verdict = %q, want %q", got, tc.want)
			}
		})
	}
}

func TestClaimsOfSkipsSilentDatabases(t *testing.T) {
	got := claimsOf([]Lookup{
		{Source: "ip-api.com", Kind: KindIDC, KindClaim: "hosting=true"},
		{Source: "ipwho.is"},
		{Source: "ipinfo.io", Kind: KindHome, KindClaim: "type=isp"},
		{Source: "ip.sb", Fail: fail(FailTimeout, "")},
	})
	want := []Basis{
		{Source: "ip-api.com", Kind: KindIDC, Claim: "hosting=true"},
		{Source: "ipinfo.io", Kind: KindHome, Claim: "type=isp"},
	}
	if !reflect.DeepEqual(got, want) {
		t.Errorf("claimsOf = %+v, want %+v", got, want)
	}
}

// TestCells is the presentation contract: an empty field is a dash, a database with no
// flag field is not the same as one that checked and found nothing, and a failed row
// carries no values at all.
func TestCells(t *testing.T) {
	cases := []struct {
		name string
		in   Lookup
		want []string
	}{
		{
			name: "a full answer",
			in: Lookup{Source: "ip-api.com", Country: "US", City: "Los Angeles", ASN: "AS64500",
				ISP: "Example Hosting LLC", Kind: KindIDC, FlagsKnown: true, Flags: []string{FlagHosting}},
			want: []string{"ip-api.com", "US · Los Angeles", "AS64500", "Example Hosting LLC", "机房", "hosting"},
		},
		{
			name: "a database that checked and found nothing",
			in:   Lookup{Source: "ip2location.io", Country: "SG", ASN: "AS64509", FlagsKnown: true},
			want: []string{"ip2location.io", "SG", "AS64509", "—", "—", "无"},
		},
		{
			name: "a database with no flag field at all",
			in:   Lookup{Source: "ipwho.is", Country: "AU", City: "Sydney"},
			want: []string{"ipwho.is", "AU · Sydney", "—", "—", "—", "—"},
		},
		{
			name: "a failed answer",
			in:   Lookup{Source: "ip.sb", Fail: fail(FailStatus, "HTTP 503")},
			want: []string{"ip.sb", "—", "—", "—", "—", "查询失败（HTTP 503）"},
		},
		{
			name: "a country without a city",
			in:   Lookup{Source: "db-ip.com", Country: "US", FlagsKnown: true},
			want: []string{"db-ip.com", "US", "—", "—", "—", "无"},
		},
		{
			name: "a risk marker beside the flags",
			in: Lookup{Source: "ipinfo.io", Country: "DE", Kind: KindMobile,
				FlagsKnown: true, Flags: []string{FlagVPN}, Risk: "VPN 服务 ExampleVPN"},
			want: []string{"ipinfo.io", "DE", "—", "—", "移动网络", "vpn, VPN 服务 ExampleVPN"},
		},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			got := tc.in.cells()
			if !reflect.DeepEqual(got, tc.want) {
				t.Errorf("cells = %v, want %v", got, tc.want)
			}
		})
	}
}

func TestFailureText(t *testing.T) {
	cases := []struct {
		name string
		in   Failure
		want string
	}{
		{name: "timeout", in: Failure{Reason: FailTimeout}, want: "超时"},
		{name: "rate limit", in: Failure{Reason: FailRateLimit, Detail: "HTTP 429"}, want: "限流 · HTTP 429"},
		{name: "refused", in: Failure{Reason: FailRefused, Detail: "HTTP 403"}, want: "服务拒绝 · HTTP 403"},
		{name: "status", in: Failure{Reason: FailStatus, Detail: "HTTP 503"}, want: "HTTP 503"},
		{name: "status without a code", in: Failure{Reason: FailStatus}, want: "非 2xx 状态"},
		{name: "transport", in: Failure{Reason: FailTransport, Detail: "connection refused"}, want: "网络错误 · connection refused"},
		{name: "parse", in: Failure{Reason: FailParse}, want: "响应无法解析"},
		{name: "missing field", in: Failure{Reason: FailField, Detail: "asn"}, want: "字段缺失 · asn"},
		{name: "an unknown reason still says something", in: Failure{Reason: "weird"}, want: "未知错误"},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			if got := tc.in.Text(); got != tc.want {
				t.Errorf("Text() = %q, want %q", got, tc.want)
			}
		})
	}
}
