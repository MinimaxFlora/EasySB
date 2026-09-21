package tui

import (
	"testing"
	"time"
)

func TestHumanBytes(t *testing.T) {
	cases := map[uint64]string{
		0:          "0 B",
		1023:       "1023 B",
		1024:       "1.0 KiB",
		1536:       "1.5 KiB",
		1 << 20:    "1.0 MiB",
		1 << 30:    "1.0 GiB",
		3 << 30:    "3.0 GiB",
		1536 << 20: "1.5 GiB",
	}
	for in, want := range cases {
		if got := humanBytes(in); got != want {
			t.Errorf("humanBytes(%d) = %q, want %q", in, got, want)
		}
	}
}

func TestUsageCell(t *testing.T) {
	if got := usageCell(0, 0); got != "" {
		t.Fatalf("unknown total should render empty, got %q", got)
	}
	if got := usageCell(1000, 400); got != "600 B / 1000 B (60%)" {
		t.Fatalf("usage = %q", got)
	}
	// Free bytes can exceed the total on overlay filesystems; clamp the clamp.
	if got := usageCell(1000, 5000); got != "0 B / 1000 B (0%)" {
		t.Fatalf("clamped usage = %q", got)
	}
}

func TestHumanDuration(t *testing.T) {
	cases := map[time.Duration]string{
		0:                "",
		30 * time.Second: "0m",
		90 * time.Minute: "1h 30m",
		25 * time.Hour:   "1d 1h 0m",
		3*24*time.Hour + 4*time.Hour + 5*time.Minute: "3d 4h 5m",
	}
	for in, want := range cases {
		if got := humanDuration(in); got != want {
			t.Errorf("humanDuration(%s) = %q, want %q", in, got, want)
		}
	}
}
