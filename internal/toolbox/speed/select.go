package speed

import (
	"fmt"
	"sort"
	"strings"
)

// server is one entry of the speedtest.net list, reduced to the fields the table shows
// and the choice needs.
type server struct {
	// id is speedtest.net's server id.
	id string
	// name is the server's place as the list labels it, e.g. "Guangzhou".
	name string
	// host is the test endpoint, the fallback when the list has no name.
	host string
	// sponsor is the operator running the server, e.g. "China Telecom Guangdong".
	sponsor string
	// distance is kilometres from this host to the server, as speedtest.net computed
	// it. Zero means the list reported none.
	distance float64
}

// carrierNames are the three mainland China carriers, in the order a report lists them.
// The name doubles as the keyword a server's name or sponsor has to contain: those
// sponsors are written in Chinese, so a keyword match is also a mainland match and needs
// no second country check.
var carrierNames = []string{"电信", "联通", "移动"}

// carrierOf returns the carrier a server belongs to, or "" when it is none of the three.
func carrierOf(srv server) string {
	text := srv.name + " " + srv.sponsor
	for _, carrier := range carrierNames {
		if strings.Contains(text, carrier) {
			return carrier
		}
	}
	return ""
}

// sortedByDistance returns the list nearest first.
//
// The speedtest.net list already arrives sorted by distance, but the order is repeated
// here so the choice does not depend on the runner: an injected list may be in any
// order. A server whose distance the list did not report (0) keeps its place behind the
// ones it did, instead of sorting in front of them as an unknown zero would.
func sortedByDistance(servers []server) []server {
	out := append([]server(nil), servers...)
	sort.SliceStable(out, func(i, j int) bool {
		a, b := out[i].distance, out[j].distance
		switch {
		case a <= 0 && b <= 0:
			return false // two unknowns keep the list's own order
		case a <= 0:
			return false
		case b <= 0:
			return true
		default:
			return a < b
		}
	})
	return out
}

// pickNearest returns the n nearest servers, nearest first. An n beyond the list length
// means the whole list; n <= 0 means none.
func pickNearest(servers []server, n int) []server {
	if n <= 0 {
		return nil
	}
	sorted := sortedByDistance(servers)
	if n < len(sorted) {
		sorted = sorted[:n]
	}
	return sorted
}

// pickCarriers returns the nearest server of each carrier the list carries, in the order
// 电信, 联通, 移动.
//
// One server per carrier, not every server of a carrier: the three networks are what the
// entry is for, and this is also what keeps a run inside the tool's timeout when the
// list carries dozens of Chinese servers. A carrier with no server in the list
// contributes no row, and the run says which ones were missing.
func pickCarriers(servers []server) []server {
	sorted := sortedByDistance(servers)
	out := make([]server, 0, len(carrierNames))
	for _, carrier := range carrierNames {
		for _, srv := range sorted {
			if carrierOf(srv) == carrier {
				out = append(out, srv)
				break
			}
		}
	}
	return out
}

// carrierCounts counts the chosen servers per carrier, so a report can say what it is
// actually testing.
func carrierCounts(servers []server) []string {
	out := make([]string, 0, len(carrierNames))
	for _, carrier := range carrierNames {
		n := 0
		for _, srv := range servers {
			if carrierOf(srv) == carrier {
				n++
			}
		}
		if n > 0 {
			out = append(out, fmt.Sprintf("%s %d", carrier, n))
		}
	}
	return out
}
