package firewall

import (
	"testing"

	"github.com/MinimaxFlora/EasySB/internal/state"
)

func TestHopRange(t *testing.T) {
	cfg := state.Default()
	start, end, err := hopRange(cfg)
	if err != nil {
		t.Fatal(err)
	}
	if start != "2080" || end != "3000" {
		t.Fatalf("unexpected range %s:%s", start, end)
	}
}

func TestHopRangeInvalid(t *testing.T) {
	cfg := state.Default()
	cfg.HopRange = "3000"
	if _, _, err := hopRange(cfg); err == nil {
		t.Fatal("expected error for malformed hop range")
	}
}

func TestDetectNeverPanics(t *testing.T) {
	if got := Detect(); got != IPTables && got != NFTables && got != None {
		t.Fatalf("unexpected backend %q", got)
	}
}
