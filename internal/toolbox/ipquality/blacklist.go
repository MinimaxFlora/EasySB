package ipquality

import (
	"context"
	"errors"
	"fmt"
	"net"
	"net/netip"
	"strings"
	"sync"
)

// zones are the blocklists the tool asks, in the order the panel lists them: the big
// combined zones an operator meets first (Spamhaus ZEN, Barracuda, SpamCop), the regional
// ones (SORBS, and anti-spam.org.cn for Chinese mail), the exploit and proxy lists, and
// UCEPROTECT's level 1 and 2, which differ in what they punish. A zone that answers for
// the address is a hit; the report names the zone and the address it returned, because
// the individual codes in 127.0.0.x say why the listing happened.
//
// Two of these were measured to answer in ways the tool has to classify rather than
// believe: zen.spamhaus.org returns 127.255.255.254 to a query that arrives through a
// public resolver (a refusal, never a listing), and every name under
// cbl.anti-spam.org.cn resolves to a public address, so that zone is reported as
// unreached for any address rather than as a hit.
var zones = []string{
	"zen.spamhaus.org",
	"b.barracudacentral.org",
	"bl.spamcop.net",
	"dnsbl.sorbs.net",
	"spam.dnsbl.sorbs.net",
	"ubl.unsubscore.com",
	"dnsbl-1.uceprotect.net",
	"dnsbl-2.uceprotect.net",
	"psbl.surriel.com",
	"cbl.anti-spam.org.cn",
	"spam.rbl.msrbl.net",
	"dnsbl.dronebl.org",
}

// Zones returns the blocklists the tool queries, in list order.
func Zones() []string { return append([]string(nil), zones...) }

// listingPrefix is where every DNSBL puts its answer: an address inside 127.0.0.0/8. That
// convention is exactly what makes a hit distinguishable from a hijacked answer, because a
// resolver that answers every name — a sinkhole, a fake-ip proxy, a resolver that
// fabricates replies — otherwise makes every zone look like a listing.
var listingPrefix = netip.MustParsePrefix("127.0.0.0/8")

// refusedPrefix is the block Spamhaus answers from when a query arrives through a public
// resolver: 127.255.255.254 and .255 mean "ask me from your own resolver". Reporting one
// as a listing would put a false black mark on an address.
var refusedPrefix = netip.MustParsePrefix("127.255.255.0/24")

// Blocklist is one zone's answer.
type Blocklist struct {
	// Zone is the blocklist domain that was queried.
	Zone string
	// Listed says the zone answered for the address with an address in 127.0.0.0/8,
	// which is how every DNSBL reports a listing.
	Listed bool
	// Answers holds the 127.0.0.0/8 addresses the zone returned. They are kept
	// because the codes inside them say why the address is listed.
	Answers []string
	// Err is why the zone reached no verdict: a timeout, a refused query, an answer
	// that is not a listing code, a resolver failure. Empty with Listed false is a
	// clean miss.
	Err string
}

// blocklists queries every zone for the address. The queries run concurrently under the
// checker's concurrency cap: a dozen sequential DNS lookups against a resolver that
// answers slowly would dominate the whole run.
func (c *Checker) blocklists(ctx context.Context, ip string) []Blocklist {
	reversed := reverseIP(ip)
	if reversed == "" {
		// Not an IPv4 literal: the query form does not exist, so nothing is
		// asked and the report says so instead of pretending to a result.
		out := make([]Blocklist, len(zones))
		for i, z := range zones {
			out[i] = Blocklist{Zone: z, Err: "地址不是 IPv4，无法构造查询名"}
		}
		return out
	}
	out := make([]Blocklist, len(zones))
	sem := make(chan struct{}, c.concurrency)
	var wg sync.WaitGroup
	for i, z := range zones {
		wg.Add(1)
		go func(i int, zone string) {
			defer wg.Done()
			sem <- struct{}{}
			defer func() { <-sem }()
			out[i] = c.queryZone(ctx, zone, reversed+"."+zone)
		}(i, z)
	}
	wg.Wait()
	return out
}

// queryZone asks one blocklist about one query name.
func (c *Checker) queryZone(ctx context.Context, zone, name string) Blocklist {
	answers, err := c.lookupHost(ctx, name)
	switch {
	case err == nil && len(answers) == 0:
		// A resolver that returns success with no address leaves the question
		// unanswered rather than answered "no".
		return Blocklist{Zone: zone, Err: "解析成功但没有返回地址"}
	case err == nil:
		listed, refused, foreign := classifyAnswers(answers)
		switch {
		case len(refused) > 0:
			return Blocklist{Zone: zone, Err: "服务拒绝查询（需用本机自有解析器）"}
		case len(listed) > 0:
			return Blocklist{Zone: zone, Listed: true, Answers: listed}
		case len(foreign) > 0:
			// The address itself is left out of the reason so that the twelve
			// zones a hijacking resolver answers for one and the same wrong
			// address collapse into a single note instead of a page of them.
			// The wording covers both cases this catches: a local resolver
			// that answers every name, and a zone that stopped following the
			// convention (cbl.anti-spam.org.cn answers a public address for
			// every name, measured with a public resolver).
			return Blocklist{Zone: zone, Err: "解析器返回了非 127.0.0.0/8 的地址（该域未按 DNSBL 约定应答，或本地 DNS 被劫持），无法判断"}
		}
		return Blocklist{Zone: zone, Err: "解析成功但没有返回地址"}
	case isNotFound(err):
		return Blocklist{Zone: zone}
	default:
		return Blocklist{Zone: zone, Err: queryError(err)}
	}
}

// classifyAnswers sorts a zone's addresses into the three things they can mean: a listing
// (127.0.0.0/8), a refusal to answer for this resolver (127.255.255.0/24), or an answer
// that cannot be a listing at all. The last group matters: a resolver that answers every
// name makes all twelve zones look like hits, and a tool that believed it would put a
// false black mark on a clean address.
func classifyAnswers(answers []string) (listed, refused, foreign []string) {
	for _, a := range answers {
		addr, err := netip.ParseAddr(a)
		switch {
		case err == nil && addr.Is4() && refusedPrefix.Contains(addr):
			refused = append(refused, a)
		case err == nil && addr.Is4() && listingPrefix.Contains(addr):
			listed = append(listed, a)
		default:
			foreign = append(foreign, a)
		}
	}
	return listed, refused, foreign
}

// lookupHost runs one DNS query under the request timeout, so a resolver that never
// answers costs one timeout rather than the whole run.
func (c *Checker) lookupHost(ctx context.Context, name string) ([]string, error) {
	qctx, cancel := context.WithTimeout(ctx, c.reqTimeout)
	defer cancel()
	return c.resolver.LookupHost(qctx, name)
}

// lookupAddr runs one reverse query under the same budget.
func (c *Checker) lookupAddr(ctx context.Context, addr string) ([]string, error) {
	qctx, cancel := context.WithTimeout(ctx, c.reqTimeout)
	defer cancel()
	return c.resolver.LookupAddr(qctx, addr)
}

// isNotFound reports the answer a blocklist gives for an address it does not list:
// NXDOMAIN, which a resolver surfaces as a not-found error. Every other error means the
// question was not answered and must not be read as a miss.
func isNotFound(err error) bool {
	var dnsErr *net.DNSError
	if errors.As(err, &dnsErr) {
		return dnsErr.IsNotFound
	}
	return false
}

// queryError names a DNS failure in the words the panel already uses for HTTP ones.
func queryError(err error) string {
	switch {
	case errors.Is(err, context.Canceled):
		return "查询已取消"
	case errors.Is(err, context.DeadlineExceeded) || isTimeout(err):
		return "查询超时"
	}
	var dnsErr *net.DNSError
	if errors.As(err, &dnsErr) && dnsErr.Err != "" {
		return "查询失败（" + dnsErr.Err + "）"
	}
	return "查询失败"
}

// reverse resolves the address's PTR names and checks them forward. A PTR that does not
// resolve back to the same address is worse than no PTR at all — mail systems read the
// mismatch as a spam signal — so the two are reported separately instead of as one
// "reverse DNS looks fine".
func (c *Checker) reverse(ctx context.Context, ip string) (names []string, fcrDNS bool, notes []string) {
	if !isIPv4(ip) {
		return nil, false, []string{"反向 DNS（PTR）：地址不是 IPv4，未查询"}
	}
	found, err := c.lookupAddr(ctx, ip)
	switch {
	case isNotFound(err):
		return nil, false, []string{"反向 DNS（PTR）：无记录"}
	case err != nil:
		return nil, false, []string{"反向 DNS（PTR）：查询失败（" + queryError(err) + "）"}
	case len(found) == 0:
		return nil, false, []string{"反向 DNS（PTR）：解析成功但没有返回名称"}
	}
	// A PTR name arrives fully qualified, with a trailing dot. It is dropped for both
	// the forward question and the report, so the name reads the way the operator would
	// type it. The resolver's own slice is copied rather than edited: a fake resolver's
	// table is not the tool's to rewrite.
	names = make([]string, 0, len(found))
	for _, name := range found {
		names = append(names, strings.TrimSuffix(name, "."))
	}

	for _, name := range names {
		addrs, err := c.lookupHost(ctx, name)
		if err != nil {
			continue
		}
		for _, a := range addrs {
			if a == ip {
				return names, true, []string{fmt.Sprintf("反向 DNS（PTR）：%s（正向验证一致）", strings.Join(names, "、"))}
			}
		}
	}
	// Every PTR name failed to confirm, which includes the case where none of them
	// resolves at all: both are a mismatch to report.
	return names, false, []string{fmt.Sprintf("反向 DNS（PTR）：%s（正向验证不一致：没有解析回 %s）",
		strings.Join(names, "、"), ip)}
}

// reverseIP turns a dotted IPv4 into the query form the DNSBLs and the in-addr.arpa tree
// use, e.g. "203.0.113.7" into "7.113.0.203". It returns an empty string for anything
// that is not four numeric octets, because a malformed query name would be answered by
// some resolvers with a search-domain lookup instead of a failure.
func reverseIP(ip string) string {
	parts := strings.Split(ip, ".")
	if len(parts) != 4 {
		return ""
	}
	for _, p := range parts {
		if p == "" || len(p) > 3 {
			return ""
		}
		for _, r := range p {
			if r < '0' || r > '9' {
				return ""
			}
		}
	}
	return strings.Join([]string{parts[3], parts[2], parts[1], parts[0]}, ".")
}
