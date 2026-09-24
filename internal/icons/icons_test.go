package icons

import (
	"os"
	"testing"

	"charm.land/lipgloss/v2"
)

// palettes names every palette the panel can draw with, so a new one cannot be
// added without also being checked here.
func palettes() map[string]Set {
	return map[string]Set{
		"symbols": Symbols(),
		"ascii":   ASCII(),
	}
}

// TestEveryGlyphIsOneColumn is the invariant the whole layout rests on: icons are
// drawn inside fixed-width rows, so a glyph that renders two cells wide would
// shift everything after it.
func TestEveryGlyphIsOneColumn(t *testing.T) {
	for name, set := range palettes() {
		for field, glyph := range map[string]string{
			"Host": set.Host, "Service": set.Service, "Running": set.Running,
			"Stopped": set.Stopped, "Enabled": set.Enabled, "Disabled": set.Disabled,
			"Bullet": set.Bullet, "Arrow": set.Arrow, "OK": set.OK, "Warn": set.Warn,
			"Err": set.Err, "Info": set.Info, "Core": set.Core, "Rocket": set.Rocket,
			"Globe": set.Globe, "Account": set.Account, "Subscribe": set.Subscribe,
			"Link": set.Link, "QR": set.QR, "Tool": set.Tool, "Refresh": set.Refresh,
			"Speed": set.Speed,
			"Trash": set.Trash, "Download": set.Download,
		} {
			if glyph == "" {
				t.Errorf("%s.%s is empty", name, field)
				continue
			}
			if got := lipgloss.Width(glyph); got != 1 {
				t.Errorf("%s.%s = %q is %d cells wide, want 1", name, field, glyph, got)
			}
		}
	}
}

// TestPalettesHaveDistinctIDs keeps Detect readable: the id is what a diagnostics
// screen prints, and two palettes answering to the same name would make that
// output a lie.
func TestPalettesHaveDistinctIDs(t *testing.T) {
	seen := map[string]bool{}
	for _, set := range palettes() {
		if seen[set.ID] {
			t.Fatalf("duplicate palette id %q", set.ID)
		}
		seen[set.ID] = true
	}
}

func TestDetectSelectsPalette(t *testing.T) {
	cases := map[string]string{
		"":          "symbols",
		"1":         "symbols",
		"on":        "symbols",
		"symbols":   "symbols",
		"unicode":   "symbols",
		"nerd":      "symbols",
		"0":         "ascii",
		"off":       "ascii",
		"false":     "ascii",
		"ascii":     "ascii",
		"plain":     "ascii",
		"  ASCII  ": "ascii",
	}
	for value, want := range cases {
		t.Setenv("EASYSB_ICONS", value)
		if got := Detect().ID; got != want {
			t.Errorf("EASYSB_ICONS=%q gave %q, want %q", value, got, want)
		}
	}

	// An unset variable is the common case and must land on the default palette.
	if err := os.Unsetenv("EASYSB_ICONS"); err != nil {
		t.Fatal(err)
	}
	if got := Detect().ID; got != "symbols" {
		t.Errorf("unset EASYSB_ICONS gave %q, want symbols", got)
	}
}
