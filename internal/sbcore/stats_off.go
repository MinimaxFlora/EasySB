//go:build !with_v2ray_api

package sbcore

// StatsAvailable reports whether this build carries the V2Ray API the per-account
// counters are read from. A build without the tag cannot serve it, and a config naming
// experimental.v2ray_api would be rejected whole, so the deploy path leaves the block out.
func StatsAvailable() bool { return false }
