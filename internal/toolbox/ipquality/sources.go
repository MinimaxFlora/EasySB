package ipquality

import (
	"encoding/json"
	"strconv"
	"strings"
)

// Kind is what a database says an address is used for, and what the report concludes.
// The value is what tests and the verdict compare; Label is what the panel shows.
type Kind string

const (
	// KindIDC is a datacenter or hosting range: a VPS.
	KindIDC Kind = "idc"
	// KindHome is a residential line.
	KindHome Kind = "home"
	// KindBusiness is a business line: an office, or an ISP's corporate range.
	KindBusiness Kind = "business"
	// KindMobile is a mobile carrier range.
	KindMobile Kind = "mobile"
	// KindMixed is the verdict when two databases disagree. It is not a compromise:
	// the panel prints every claim behind it.
	KindMixed Kind = "mixed"
	// KindUnknown is the verdict when no database said anything about the line.
	KindUnknown Kind = "unknown"
)

// Label is the Chinese word for a kind. The empty kind — a database that made no claim —
// is deliberately not one of these: a table cell renders it as a dash.
func (k Kind) Label() string {
	switch k {
	case KindIDC:
		return "机房"
	case KindHome:
		return "家宽"
	case KindBusiness:
		return "商宽"
	case KindMobile:
		return "移动网络"
	case KindMixed:
		return "不一致"
	default:
		return "未知"
	}
}

// Flags a database may report. The values are the English words the databases
// themselves use, printed as they are.
const (
	// FlagProxy marks an anonymising proxy.
	FlagProxy = "proxy"
	// FlagVPN marks a commercial VPN exit.
	FlagVPN = "vpn"
	// FlagTor marks a Tor exit node.
	FlagTor = "tor"
	// FlagRelay marks a privacy relay (Apple Private Relay and friends).
	FlagRelay = "relay"
	// FlagHosting marks a hosting or datacenter range.
	FlagHosting = "hosting"
	// FlagMobile marks a mobile carrier range.
	FlagMobile = "mobile"
	// FlagAnycast marks an anycast address.
	FlagAnycast = "anycast"
	// FlagBogon marks an address that is not routable on the open internet.
	FlagBogon = "bogon"
)

// FailReason is why one lookup reached no answer. It is a code, so the reason a source
// failed can be asserted in a test without matching prose.
type FailReason string

// The reasons a lookup can fail. Field covers an answer that arrived without what the
// source promises, which is the one case where the rest of the row is still shown.
const (
	// FailTimeout means the request or query did not answer in time.
	FailTimeout FailReason = "timeout"
	// FailRateLimit means the endpoint refused the request as too frequent.
	FailRateLimit FailReason = "rate_limited"
	// FailRefused means the endpoint refused this caller (a 403, or a database that
	// declines to answer for a reserved address).
	FailRefused FailReason = "refused"
	// FailStatus means the endpoint answered with an unexpected status code.
	FailStatus FailReason = "http_status"
	// FailTransport means the connection failed.
	FailTransport FailReason = "transport"
	// FailParse means the body was not the JSON the source promises.
	FailParse FailReason = "unparsable"
	// FailField means the answer did not carry a field the source promises.
	FailField FailReason = "missing_field"
)

// Failure is why a lookup reached no answer.
type Failure struct {
	// Reason is the code the tests assert on.
	Reason FailReason
	// Detail is the specific evidence: "HTTP 503", "as", "reserved range". Empty
	// when the reason says everything.
	Detail string
}

// fail builds a Failure.
func fail(reason FailReason, detail string) *Failure {
	return &Failure{Reason: reason, Detail: detail}
}

// Text is the reason as the panel prints it, e.g. "超时", "限流（HTTP 429）",
// "字段缺失（asn）".
func (f Failure) Text() string {
	switch f.Reason {
	case FailTimeout:
		return withDetail("超时", f.Detail)
	case FailRateLimit:
		return withDetail("限流", f.Detail)
	case FailRefused:
		return withDetail("服务拒绝", f.Detail)
	case FailTransport:
		return withDetail("网络错误", f.Detail)
	case FailParse:
		return withDetail("响应无法解析", f.Detail)
	case FailField:
		return withDetail("字段缺失", f.Detail)
	case FailStatus:
		if f.Detail == "" {
			return "非 2xx 状态"
		}
		return f.Detail
	}
	return withDetail("未知错误", f.Detail)
}

// withDetail joins a reason with its evidence. The separator is a middle dot rather than
// parentheses because the whole phrase is itself wrapped in parentheses by the row and
// the note, and nesting them reads badly.
func withDetail(name, detail string) string {
	if detail == "" {
		return name
	}
	return name + " · " + detail
}

// Lookup is one database's answer about the address.
type Lookup struct {
	// Source is the database name, the same string the table's 来源 column shows.
	Source string
	// Country is the country code the database reported, or its country name when it
	// reported no code. Empty means it reported neither.
	Country string
	// City is the city the database reported. Empty when it reported none — a
	// database that answers without a city is normal for some countries.
	City string
	// ASN is the announcing autonomous system, e.g. "AS64500". Empty when the
	// database reported none.
	ASN string
	// ISP is the network operator name the database reported.
	ISP string
	// Kind is the use the database asserted, empty when it asserted none.
	Kind Kind
	// KindClaim is the field and value behind Kind (e.g. "hosting",
	// "company.type=business"), carried so the verdict note can quote the evidence
	// instead of an unattributed conclusion.
	KindClaim string
	// FlagsKnown says the database answered the proxy/VPN/Tor question at all. It
	// separates "checked, nothing found" from "cannot check", which the panel must
	// not print the same way.
	FlagsKnown bool
	// Flags are the markers the database reported.
	Flags []string
	// Risk is a risk marker that is not a flag (an abuse score, a named VPN
	// service). Empty when the database reported none.
	Risk string
	// Missing names the promised fields the answer did not carry. The rest of the
	// row is still shown: an answer that lost one field is more useful than none.
	Missing []string
	// Fail is why the database did not answer at all. A failed lookup carries no
	// other field, because a broken response is never half-trusted.
	Fail *Failure
}

// cells renders one database row for the panel's table.
func (l Lookup) cells() []string {
	if l.Fail != nil {
		return []string{l.Source, dash, dash, dash, dash, "查询失败（" + l.Fail.Text() + "）"}
	}
	return []string{
		l.Source,
		location(l.Country, l.City),
		orDash(l.ASN),
		orDash(l.ISP),
		kindCell(l.Kind),
		l.riskCell(),
	}
}

// dash is what an empty cell shows. It means "the database reported nothing here",
// which is deliberately not the same as a value.
const dash = "—"

// orDash returns s, or a dash when the source reported nothing.
func orDash(s string) string {
	if s == "" {
		return dash
	}
	return s
}

// kindCell renders a database's own claim. An empty claim is a dash, never 未知: the
// database has not said "unknown", it has said nothing, and only the report's verdict
// line may conclude 未知.
func kindCell(k Kind) string {
	if k == "" {
		return dash
	}
	return k.Label()
}

// location joins the country and city a database reported.
func location(country, city string) string {
	switch {
	case country == "" && city == "":
		return dash
	case country == "":
		return city
	case city == "":
		return country
	}
	return country + " · " + city
}

// riskCell renders the markers a database reported. A database that answers the question
// with nothing gets 无; one that has no such field at all gets a dash, because the two
// are different statements and an operator reads this column to decide whether the
// address is a problem.
func (l Lookup) riskCell() string {
	parts := append([]string(nil), l.Flags...)
	if l.Risk != "" {
		parts = append(parts, l.Risk)
	}
	if len(parts) > 0 {
		return strings.Join(parts, ", ")
	}
	if l.FlagsKnown {
		return "无"
	}
	return dash
}

// Basis is one database's line-kind claim, kept beside the raw field it came from.
type Basis struct {
	Source string
	Kind   Kind
	Claim  string
}

// claimsOf collects the claims the answerers made, in catalogue order.
func claimsOf(lookups []Lookup) []Basis {
	var out []Basis
	for _, l := range lookups {
		if l.Kind == "" {
			continue
		}
		out = append(out, Basis{Source: l.Source, Kind: l.Kind, Claim: l.KindClaim})
	}
	return out
}

// verdict folds the claims into one answer. A single kind wins; two different kinds are
// reported as mixed, because picking one would be inventing a consensus the databases
// never reached.
func verdict(basis []Basis) Kind {
	if len(basis) == 0 {
		return KindUnknown
	}
	k := basis[0].Kind
	for _, b := range basis[1:] {
		if b.Kind != k {
			return KindMixed
		}
	}
	return k
}

// source describes one database: the URL to ask, how to read the answer, and whether the
// keyless answer carries a line-kind or a proxy/VPN/Tor field at all.
type source struct {
	// name is what the panel shows and what every note names.
	name string
	// url builds the request URL for an address.
	url func(ip string) string
	// parse reads one answer. It returns either the answer or a Failure, never both.
	parse func(body []byte) Lookup
	// kind and flags say whether this endpoint reports a line kind and whether it
	// reports proxy/VPN/Tor markers. They drive one note that tells an operator a dash
	// in the table means "this database has no such field" rather than "nothing here".
	kind  bool
	flags bool
}

// catalogue is every database, in the order the table lists them. Only free, keyless
// endpoints: a panel that ships to an operator's VPS must not need an account, and a
// key baked into the binary would be spent by whoever read the source first.
var catalogue = []source{
	{
		name: "ip-api.com",
		url: func(ip string) string {
			// The free tier answers plain HTTP only: https to ip-api.com comes
			// back 403 without a Pro key, so an https request here would look
			// like a network problem forever. The fields are named explicitly,
			// which also keeps the answer small and stable.
			return "http://ip-api.com/json/" + ip +
				"?fields=status,message,country,countryCode,city,isp,org,as,asname,proxy,hosting,mobile,query"
		},
		kind:  true,
		flags: true,
		parse: func(body []byte) Lookup {
			var raw struct {
				Status      string `json:"status"`
				Message     string `json:"message"`
				Country     string `json:"country"`
				CountryCode string `json:"countryCode"`
				City        string `json:"city"`
				ISP         string `json:"isp"`
				Org         string `json:"org"`
				AS          string `json:"as"`
				Proxy       bool   `json:"proxy"`
				Hosting     bool   `json:"hosting"`
				Mobile      bool   `json:"mobile"`
			}
			if f := decodeJSON(body, &raw); f != nil {
				return Lookup{Fail: f}
			}
			if raw.Status != "success" {
				// A fail status carries the reason in message ("reserved
				// range", "invalid query"): the database is answering, and
				// saying it will not read this address.
				message := raw.Message
				if message == "" {
					message = "status=" + raw.Status
				}
				return Lookup{Fail: fail(FailRefused, message)}
			}
			l := Lookup{
				Country:    firstNonEmpty(raw.CountryCode, raw.Country),
				City:       raw.City,
				ASN:        asnOf(raw.AS),
				ISP:        firstNonEmpty(raw.ISP, raw.Org),
				FlagsKnown: true,
			}
			switch {
			case raw.Mobile:
				// A mobile carrier range beats the hosting flag: a mobile
				// IP that also looks hosted is still a mobile line to the
				// networks that care.
				l.Kind, l.KindClaim = KindMobile, "mobile=true"
			case raw.Hosting:
				l.Kind, l.KindClaim = KindIDC, "hosting=true"
			}
			l.flag(raw.Proxy, FlagProxy)
			l.flag(raw.Hosting, FlagHosting)
			l.flag(raw.Mobile, FlagMobile)
			return withMissing(l, "country", "city", "asn", "isp")
		},
	},
	{
		name: "ipinfo.io",
		url: func(ip string) string {
			// The widget's own endpoint, not the documented /json one: the
			// documented free answer has no privacy module (that needs a
			// token) and no ASN type, while this one carries vpn/proxy/tor
			// and the company type the verdict needs. It is keyless and
			// public, which is the rule, but it is not versioned — the
			// parser therefore reads fields by name and fails loudly if the
			// shape changes.
			return "https://ipinfo.io/widget/demo/" + ip
		},
		kind:  true,
		flags: true,
		parse: func(body []byte) Lookup {
			var raw struct {
				Data struct {
					City    string `json:"city"`
					Country string `json:"country"`
					Org     string `json:"org"`
					ASN     struct {
						ASN  string `json:"asn"`
						Name string `json:"name"`
						Type string `json:"type"`
					} `json:"asn"`
					Company struct {
						Name string `json:"name"`
						Type string `json:"type"`
					} `json:"company"`
					Privacy struct {
						VPN     bool   `json:"vpn"`
						Proxy   bool   `json:"proxy"`
						Tor     bool   `json:"tor"`
						Relay   bool   `json:"relay"`
						Hosting bool   `json:"hosting"`
						Service string `json:"service"`
					} `json:"privacy"`
					IsMobile    bool `json:"is_mobile"`
					IsAnycast   bool `json:"is_anycast"`
					IsAnonymous bool `json:"is_anonymous"`
				} `json:"data"`
			}
			if f := decodeJSON(body, &raw); f != nil {
				return Lookup{Fail: f}
			}
			d := raw.Data
			l := Lookup{
				Country:    d.Country,
				City:       d.City,
				ASN:        asnOf(d.ASN.ASN),
				ISP:        firstNonEmpty(d.Company.Name, d.Org, d.ASN.Name),
				FlagsKnown: true,
			}
			// The company type is ipinfo's own line-kind claim: hosting is a
			// datacenter, business a commercial range, isp a consumer ISP.
			// is_mobile wins when set, because a carrier's range is the more
			// specific statement.
			switch {
			case d.IsMobile:
				l.Kind, l.KindClaim = KindMobile, "is_mobile=true"
			case d.Company.Type == FlagHosting || d.ASN.Type == FlagHosting:
				l.Kind, l.KindClaim = KindIDC, "type=hosting"
			case d.Company.Type == string(KindBusiness):
				l.Kind, l.KindClaim = KindBusiness, "company.type=business"
			case d.ASN.Type == "isp" || d.Company.Type == "isp":
				l.Kind, l.KindClaim = KindHome, "type=isp"
			}
			l.flag(d.Privacy.VPN, FlagVPN)
			l.flag(d.Privacy.Proxy, FlagProxy)
			l.flag(d.Privacy.Tor, FlagTor)
			l.flag(d.Privacy.Relay, FlagRelay)
			l.flag(d.Privacy.Hosting, FlagHosting)
			l.flag(d.IsMobile, FlagMobile)
			l.flag(d.IsAnycast, FlagAnycast)
			// A named service is a risk marker in its own right: it says which
			// VPN the address belongs to, which is what an operator wants to
			// know when a service blocks the node.
			if d.Privacy.Service != "" {
				l.Risk = "VPN 服务 " + d.Privacy.Service
			}
			return withMissing(l, "country", "city", "asn", "isp")
		},
	},
	{
		name: "ipapi.is",
		url: func(ip string) string {
			return "https://api.ipapi.is/?q=" + ip
		},
		// The keyless answer is company, ASN and location; is_datacenter,
		// is_vpn, is_proxy, is_tor and is_abuser need a free account key, which
		// this tool does not use.
		parse: func(body []byte) Lookup {
			var raw struct {
				IsBogon bool   `json:"is_bogon"`
				Company string `json:"company"`
				ASN     string `json:"asn"`
				City    string `json:"city"`
				Country string `json:"country"`
			}
			if f := decodeJSON(body, &raw); f != nil {
				return Lookup{Fail: f}
			}
			l := Lookup{
				Country: raw.Country,
				City:    raw.City,
				ASN:     asnOf(raw.ASN),
				ISP:     raw.Company,
				// is_bogon is the one flag the keyless answer carries, so the
				// question was asked; the rest of the markers were not.
				FlagsKnown: true,
			}
			l.flag(raw.IsBogon, FlagBogon)
			return withMissing(l, "country", "city", "asn", "isp")
		},
	},
	{
		name: "ipwho.is",
		url: func(ip string) string {
			return "https://ipwho.is/" + ip
		},
		parse: func(body []byte) Lookup {
			var raw struct {
				Success bool   `json:"success"`
				Message string `json:"message"`
				Country string `json:"country"`
				Code    string `json:"country_code"`
				City    string `json:"city"`
				Conn    struct {
					ASN *int64 `json:"asn"`
					ISP string `json:"isp"`
					Org string `json:"org"`
				} `json:"connection"`
			}
			if f := decodeJSON(body, &raw); f != nil {
				return Lookup{Fail: f}
			}
			if !raw.Success {
				return Lookup{Fail: fail(FailRefused, firstNonEmpty(raw.Message, "success=false"))}
			}
			l := Lookup{
				Country: firstNonEmpty(raw.Code, raw.Country),
				City:    raw.City,
				ASN:     asnOfInt(raw.Conn.ASN),
				ISP:     firstNonEmpty(raw.Conn.ISP, raw.Conn.Org),
			}
			return withMissing(l, "country", "city", "asn", "isp")
		},
	},
	{
		name: "ip.sb",
		url: func(ip string) string {
			return "https://api.ip.sb/geoip/" + ip
		},
		parse: func(body []byte) Lookup {
			var raw struct {
				Country string `json:"country"`
				Code    string `json:"country_code"`
				City    string `json:"city"`
				ISP     string `json:"isp"`
				Org     string `json:"organization"`
				ASN     *int64 `json:"asn"`
				ASNOrg  string `json:"asn_organization"`
			}
			if f := decodeJSON(body, &raw); f != nil {
				return Lookup{Fail: f}
			}
			l := Lookup{
				Country: firstNonEmpty(raw.Code, raw.Country),
				City:    raw.City,
				ASN:     asnOfInt(raw.ASN),
				ISP:     firstNonEmpty(raw.ISP, raw.Org, raw.ASNOrg),
			}
			return withMissing(l, "country", "city", "asn", "isp")
		},
	},
	{
		name: "ip2location.io",
		url: func(ip string) string {
			return "https://api.ip2location.io/?ip=" + ip
		},
		flags: true,
		parse: func(body []byte) Lookup {
			var raw struct {
				Code    string `json:"country_code"`
				Country string `json:"country_name"`
				City    string `json:"city_name"`
				ASN     string `json:"asn"`
				AS      string `json:"as"`
				IsProxy bool   `json:"is_proxy"`
				// The endpoint appends a quota notice in message; it is not a
				// risk marker and must not be read as one.
				Message string `json:"message"`
			}
			if f := decodeJSON(body, &raw); f != nil {
				return Lookup{Fail: f}
			}
			l := Lookup{
				Country:    firstNonEmpty(raw.Code, raw.Country),
				City:       raw.City,
				ASN:        asnOf(raw.ASN),
				ISP:        raw.AS,
				FlagsKnown: true,
			}
			l.flag(raw.IsProxy, FlagProxy)
			return withMissing(l, "country", "city", "asn", "isp")
		},
	},
	{
		name: "ipwhois.app",
		url: func(ip string) string {
			return "https://ipwhois.app/json/" + ip
		},
		parse: func(body []byte) Lookup {
			var raw struct {
				Success bool   `json:"success"`
				Message string `json:"message"`
				Country string `json:"country"`
				Code    string `json:"country_code"`
				City    string `json:"city"`
				ASN     string `json:"asn"`
				ISP     string `json:"isp"`
				Org     string `json:"org"`
			}
			if f := decodeJSON(body, &raw); f != nil {
				return Lookup{Fail: f}
			}
			if !raw.Success {
				return Lookup{Fail: fail(FailRefused, firstNonEmpty(raw.Message, "success=false"))}
			}
			l := Lookup{
				Country: firstNonEmpty(raw.Code, raw.Country),
				City:    raw.City,
				ASN:     asnOf(raw.ASN),
				ISP:     firstNonEmpty(raw.ISP, raw.Org),
			}
			return withMissing(l, "country", "city", "asn", "isp")
		},
	},
	{
		name: "db-ip.com",
		url: func(ip string) string {
			return "https://api.db-ip.com/v2/free/" + ip
		},
		// db-ip answers a free question with geography only: no ASN, no ISP, no
		// markers. It is kept because a second country reading is worth having,
		// and because the report has to say something about a source that
		// answers thin.
		parse: func(body []byte) Lookup {
			var raw struct {
				CountryCode string `json:"countryCode"`
				CountryName string `json:"countryName"`
				City        string `json:"city"`
			}
			if f := decodeJSON(body, &raw); f != nil {
				return Lookup{Fail: f}
			}
			return withMissing(Lookup{
				Country: firstNonEmpty(raw.CountryCode, raw.CountryName),
				City:    raw.City,
			}, "country", "city")
		},
	},
	{
		name: "ipapi.co",
		url: func(ip string) string {
			return "https://ipapi.co/" + ip + "/json/"
		},
		parse: func(body []byte) Lookup {
			var raw struct {
				Error   bool   `json:"error"`
				Reason  string `json:"reason"`
				Country string `json:"country_name"`
				Code    string `json:"country_code"`
				City    string `json:"city"`
				ASN     string `json:"asn"`
				Org     string `json:"org"`
			}
			if f := decodeJSON(body, &raw); f != nil {
				return Lookup{Fail: f}
			}
			if raw.Error {
				// The free tier says "RateLimited" here rather than with a
				// 429, so the reason decides between the two readings.
				if strings.Contains(strings.ToLower(raw.Reason), "rate") {
					return Lookup{Fail: fail(FailRateLimit, firstNonEmpty(raw.Reason, "HTTP 200"))}
				}
				return Lookup{Fail: fail(FailRefused, raw.Reason)}
			}
			l := Lookup{
				Country: firstNonEmpty(raw.Code, raw.Country),
				City:    raw.City,
				ASN:     asnOf(raw.ASN),
				ISP:     raw.Org,
			}
			return withMissing(l, "country", "city", "asn", "isp")
		},
	},
}

// decodeJSON reads a body, turning anything that is not the promised JSON (a block page,
// an HTML error) into a parse failure. The failure detail carries the decoder's message
// so an operator can tell a changed shape from a truncated read.
func decodeJSON(body []byte, v any) *Failure {
	if len(strings.TrimSpace(string(body))) == 0 {
		return fail(FailParse, "响应为空")
	}
	if err := json.Unmarshal(body, v); err != nil {
		return fail(FailParse, err.Error())
	}
	return nil
}

// withMissing records the promised fields an answer did not carry. An operator reading a
// dash needs to know the difference between "the database did not answer this" and "the
// database does not have this field", and the note built from this list carries it.
func withMissing(l Lookup, fields ...string) Lookup {
	for _, name := range fields {
		empty := false
		switch name {
		case "country":
			empty = l.Country == ""
		case "city":
			empty = l.City == ""
		case "asn":
			empty = l.ASN == ""
		case "isp":
			empty = l.ISP == ""
		}
		if empty {
			l.Missing = append(l.Missing, name)
		}
	}
	return l
}

// asnOf pulls the number out of an ASN string the databases write in their own prose,
// e.g. "AS64500 Example Hosting LLC" or a bare "64500". Only the number goes in the
// table; the operator name is already in the ISP column.
func asnOf(s string) string {
	s = strings.TrimSpace(s)
	if s == "" {
		return ""
	}
	fields := strings.Fields(s)
	first := fields[0]
	if !strings.HasPrefix(strings.ToUpper(first), "AS") {
		// Some endpoints give a bare number, or a name with no number at all:
		// keep the number when there is one, nothing otherwise.
		if _, err := strconv.Atoi(first); err != nil {
			return ""
		}
		return "AS" + first
	}
	num := strings.TrimPrefix(strings.TrimPrefix(first, "AS"), "as")
	if num == "" {
		return ""
	}
	return "AS" + num
}

// asnOfInt renders a numeric ASN the way asnOf renders a string one.
func asnOfInt(n *int64) string {
	if n == nil || *n <= 0 {
		return ""
	}
	return "AS" + strconv.FormatInt(*n, 10)
}

// firstNonEmpty returns the first non-empty string, for the fields a database may report
// in either of two forms.
func firstNonEmpty(values ...string) string {
	for _, v := range values {
		if v != "" {
			return v
		}
	}
	return ""
}

// flag records a marker a database reported, in the order the parser asks about them.
func (l *Lookup) flag(set bool, name string) {
	if set {
		l.Flags = append(l.Flags, name)
	}
}
