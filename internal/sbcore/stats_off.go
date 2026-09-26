//go:build !with_v2ray_api

package sbcore

// StatsCapable reports whether this build carries the V2Ray API. Without the
// with_v2ray_api tag the core rejects a configuration naming the API, so the
// panel may not write the experimental.v2ray_api block and cannot count traffic.
func StatsCapable() bool { return false }
