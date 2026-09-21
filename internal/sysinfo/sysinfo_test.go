package sysinfo

import (
	"testing"
	"time"
)

func TestParseCPUModel(t *testing.T) {
	x86 := "processor\t: 0\nmodel\t\t: 79\nmodel name\t: Intel(R) Xeon(R) CPU E5-2680 v4 @ 2.40GHz\n"
	if got := parseCPUModel([]byte(x86)); got != "Intel(R) Xeon(R) CPU E5-2680 v4 @ 2.40GHz" {
		t.Fatalf("x86 model = %q", got)
	}
	arm := "processor\t: 0\nModel\t\t: Raspberry Pi 4 Model B Rev 1.4\n"
	if got := parseCPUModel([]byte(arm)); got != "Raspberry Pi 4 Model B Rev 1.4" {
		t.Fatalf("arm model = %q", got)
	}
	if got := parseCPUModel([]byte("processor\t: 0\n")); got != "" {
		t.Fatalf("missing model should be empty, got %q", got)
	}
}

func TestParseLoadAvg(t *testing.T) {
	if got := parseLoadAvg([]byte("0.12 0.08 0.05 1/234 5678\n")); got != "0.12 0.08 0.05" {
		t.Fatalf("load = %q", got)
	}
	if got := parseLoadAvg([]byte("garbage")); got != "" {
		t.Fatalf("bad load should be empty, got %q", got)
	}
}

func TestParseMeminfo(t *testing.T) {
	total, avail := parseMeminfo([]byte("MemTotal: 2048000 kB\nMemFree: 200000 kB\nMemAvailable: 1024000 kB\n"))
	if total != 2048000*1024 {
		t.Fatalf("total = %d", total)
	}
	if avail != 1024000*1024 {
		t.Fatalf("avail = %d", avail)
	}
	// Kernels without MemAvailable fall back to MemFree.
	_, avail = parseMeminfo([]byte("MemTotal: 1024 kB\nMemFree: 512 kB\n"))
	if avail != 512*1024 {
		t.Fatalf("fallback avail = %d", avail)
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
