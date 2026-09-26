package backtrace

import "net"

// The target table.
//
// Source: the public target lists of the two backtrace projects the 融合怪 ecs
// script's backtrace step is built on — oneclickvirt/backtrace
// (model/model.go, Ipv4s/Ipv4Names, v0.0.21) and zhanghanyun/backtrace
// (asn.go, ips/names). Both publish the same twelve addresses: four cities
// (北京/上海/广州/成都) times the three carriers, one address each. They are
// carrier-run speed-test anchors and looking glasses, so they answer ICMP from a
// foreign host and their addresses are stable. The list is copied verbatim
// rather than fetched, so a change upstream is a deliberate edit here and the
// panel never depends on GitHub for a target table — which also means the
// targets must map to exactly the names used in the report.
//
// IPv6 targets exist upstream too (Ipv6s/Ipv6Names, 北京/上海/广州 only), but
// this tool traces over IPv4 only: the panel's hosts and the ICMP socket here are
// IPv4, and a mixed table would report rows it cannot fill.
var targetTable = []struct {
	name string
	ip   string
}{
	{"北京电信", "219.141.140.10"},
	{"北京联通", "202.106.195.68"},
	{"北京移动", "221.179.155.161"},
	{"上海电信", "202.96.209.133"},
	{"上海联通", "210.22.97.1"},
	{"上海移动", "211.136.112.200"},
	{"广州电信", "58.60.188.222"},
	{"广州联通", "210.21.196.6"},
	{"广州移动", "120.196.165.24"},
	{"成都电信", "61.139.2.69"},
	{"成都联通", "119.6.6.6"},
	{"成都移动", "211.137.96.205"},
}

// targetSourceNote is the Notes line that says where the addresses came from, so
// a report that looks wrong can be checked against the source list.
const targetSourceNote = "目标 IP 取自 oneclickvirt/backtrace（model/model.go）与 zhanghanyun/backtrace（asn.go）公开的目标表：北京/上海/广州/成都 × 电信/联通/移动"

// DefaultTargets returns the target table in report order.
func DefaultTargets() []Target {
	out := make([]Target, 0, len(targetTable))
	for _, t := range targetTable {
		out = append(out, Target{Name: t.name, IP: net.ParseIP(t.ip)})
	}
	return out
}
