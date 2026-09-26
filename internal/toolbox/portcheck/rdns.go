package portcheck

import (
	"context"
	"errors"
	"fmt"
	"net"
	"strings"
	"time"
)

// RDNSResult is what the reverse lookup found for the host's public address.
// A mailbox needs a PTR, and a PTR that resolves back to the same address: a
// name that does not (FCrDNS failure) is treated by large receivers as a forged
// sender, which is why "there is some PTR" is not the answer.
type RDNSResult struct {
	// Names are the PTR names, without the trailing dot.
	Names []string
	// Confirmed is the PTR name that resolved forward to the same address.
	Confirmed string
	// Unconfirmed are PTR names that did not resolve back to the address.
	Unconfirmed []string
	// Missing means the lookup succeeded and the address has no PTR record.
	Missing bool
	// Failed means the lookup itself did not run to an answer, so the report
	// cannot claim either way.
	Failed bool
	// Error is the failure text when Failed.
	Error string
}

// ForwardConfirmed reports that at least one PTR name resolves back to the
// probed address.
func (r RDNSResult) ForwardConfirmed() bool { return r.Confirmed != "" }

// Line is the one note line describing the reverse lookup, addressed to the
// operator who has to act on it.
func (r RDNSResult) Line(ip string) string {
	switch {
	case r.Failed:
		return fmt.Sprintf("PTR 查询失败：%s；反向解析无法确认，结论也只能是「无法确认」。", r.Error)
	case r.Missing:
		return fmt.Sprintf("PTR 缺失：%s 没有反向解析记录；邮局需要 PTR，请到运营商/云厂商控制台为该 IP 设置 rDNS/PTR，指向你的发信域名。", ip)
	case r.ForwardConfirmed():
		return fmt.Sprintf("PTR：%s（FCrDNS 一致：该名字正解回 %s）。", strings.Join(r.Names, ", "), ip)
	default:
		return fmt.Sprintf("PTR：%s 存在，但正解不回 %s（FCrDNS 不一致）；多数收信方会因此判为可疑，需要把这些名字的 A/AAAA 记录指回本机 IP。", strings.Join(r.Names, ", "), ip)
	}
}

// summaryText is the short form used in the progress log.
func (r RDNSResult) summaryText() string {
	switch {
	case r.Failed:
		return "查询失败（" + r.Error + "）"
	case r.Missing:
		return "无记录"
	case r.ForwardConfirmed():
		return strings.Join(r.Names, ", ") + "（FCrDNS 一致）"
	default:
		return strings.Join(r.Names, ", ") + "（FCrDNS 不一致）"
	}
}

// lookupRDNS reads the PTR of ip and checks it forward. Both queries share the
// dial deadline: a resolver that has stopped answering must not hold the check
// open, and the two lookups are one measurement.
func lookupRDNS(ctx context.Context, res Resolver, ip string, timeout time.Duration) RDNSResult {
	ctx, cancel := context.WithTimeout(ctx, timeout)
	defer cancel()

	names, err := res.LookupAddr(ctx, ip)
	if err != nil {
		if isNotFound(err) {
			// NXDOMAIN is the resolver's way of reporting a missing PTR, which
			// is a measurement, not a broken query.
			return RDNSResult{Missing: true}
		}
		return RDNSResult{Failed: true, Error: err.Error()}
	}

	out := RDNSResult{}
	for _, name := range names {
		// Resolvers are inconsistent about the trailing dot; the report shows
		// the name as a human would write it.
		name = strings.TrimSuffix(strings.TrimSpace(name), ".")
		if name != "" {
			out.Names = append(out.Names, name)
		}
	}
	if len(out.Names) == 0 {
		return RDNSResult{Missing: true}
	}

	for _, name := range out.Names {
		addrs, err := res.LookupHost(ctx, name)
		if err != nil || !containsIP(addrs, ip) {
			// A name that does not resolve forward at all cannot confirm the
			// address either, so it lands in the same list as one that resolves
			// elsewhere.
			out.Unconfirmed = append(out.Unconfirmed, name)
			continue
		}
		if out.Confirmed == "" {
			out.Confirmed = name
		}
	}
	return out
}

// containsIP reports whether addrs holds ip, comparing parsed addresses so a
// resolver's formatting cannot decide the answer.
func containsIP(addrs []string, ip string) bool {
	want := net.ParseIP(ip)
	if want == nil {
		return false
	}
	for _, addr := range addrs {
		if got := net.ParseIP(addr); got != nil && got.Equal(want) {
			return true
		}
	}
	return false
}

// isNotFound reports the resolver's "no such name" answer, which for a PTR
// means the address has no reverse record rather than that the query failed.
func isNotFound(err error) bool {
	var dnsErr *net.DNSError
	if errors.As(err, &dnsErr) {
		return dnsErr.IsNotFound
	}
	return false
}
