package sysinfo

import (
	"testing"
	"time"
)

func TestParseLoadAvg(t *testing.T) {
	if got := parseLoadAvg([]byte("0.12 0.08 0.05 1/234 5678\n")); got != "0.12 0.08 0.05" {
		t.Fatalf("load = %q", got)
	}
	if got := parseLoadAvg([]byte("garbage")); got != "" {
		t.Fatalf("bad load should be empty, got %q", got)
	}
}

func TestParseMeminfo(t *testing.T) {
	data := "MemTotal: 2048000 kB\nMemFree: 200000 kB\nMemAvailable: 1024000 kB\nSwapTotal: 1048576 kB\nSwapFree: 524288 kB\n"
	total, avail, swapTotal, swapFree := parseMeminfo([]byte(data))
	if total != 2048000*1024 {
		t.Fatalf("total = %d", total)
	}
	if avail != 1024000*1024 {
		t.Fatalf("avail = %d", avail)
	}
	if swapTotal != 1048576*1024 {
		t.Fatalf("swap total = %d", swapTotal)
	}
	if swapFree != 524288*1024 {
		t.Fatalf("swap free = %d", swapFree)
	}
	// Kernels without MemAvailable fall back to MemFree, and hosts without swap
	// report zero.
	_, avail, swapTotal, _ = parseMeminfo([]byte("MemTotal: 1024 kB\nMemFree: 512 kB\n"))
	if avail != 512*1024 {
		t.Fatalf("fallback avail = %d", avail)
	}
	if swapTotal != 0 {
		t.Fatalf("missing swap should be 0, got %d", swapTotal)
	}
}

func TestParseUptime(t *testing.T) {
	got := parseUptime([]byte("12345.67 98765.43\n"))
	want := time.Duration(12345.67 * float64(time.Second))
	if diff := got - want; diff < -time.Second || diff > time.Second {
		t.Fatalf("uptime = %s, want ~%s", got, want)
	}
	if got := parseUptime(nil); got != 0 {
		t.Fatalf("empty uptime = %s, want 0", got)
	}
}
