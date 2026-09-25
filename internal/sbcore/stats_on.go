//go:build with_v2ray_api

package sbcore

// StatsAvailable reports whether this build carries the V2Ray API the per-account
// counters are read from. The tag is what decides it: without it, sing-box rejects a
// config naming experimental.v2ray_api whole, so a deployment carries no stats block.
func StatsAvailable() bool { return true }
