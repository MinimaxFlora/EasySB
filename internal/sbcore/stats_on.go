//go:build with_v2ray_api

package sbcore

// StatsCapable reports whether this build carries the V2Ray API, the traffic
// counters the panel reads per account. It is a compile-time answer: the tag
// decides whether the core knows the API at all.
func StatsCapable() bool { return true }
