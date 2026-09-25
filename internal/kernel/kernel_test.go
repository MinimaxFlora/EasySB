package kernel

import (
	"testing"

	"github.com/MinimaxFlora/EasySB/internal/core"
)

// A request that leaves parts open gets what a fresh install should have: the author
// source's stable channel, the build per-account accounting reads.
func TestRequestNormalize(t *testing.T) {
	cases := []struct {
		name string
		in   Request
		want Request
	}{
		{
			"zero value takes the default combination",
			Request{},
			Request{Channel: "stable", Source: core.SourceBuild, DoneKey: "kernel_installed"},
		},
		{
			"alpha is kept",
			Request{Channel: "alpha", Source: core.SourceBuild},
			Request{Channel: "alpha", Source: core.SourceBuild, DoneKey: "kernel_installed"},
		},
		{
			"the official source is kept",
			Request{Channel: "stable", Source: core.SourceUpstream},
			Request{Channel: "stable", Source: core.SourceUpstream, DoneKey: "kernel_installed"},
		},
		{
			"an unknown channel or source falls back instead of failing the install",
			Request{Channel: "beta", Source: "somewhere"},
			Request{Channel: "stable", Source: core.SourceBuild, DoneKey: "kernel_installed"},
		},
		{
			"a caller's closing line is not overwritten",
			Request{Channel: "stable", DoneKey: "kernel_updated"},
			Request{Channel: "stable", Source: core.SourceBuild, DoneKey: "kernel_updated"},
		},
		{
			"the installer's skip-when-present wish survives normalization",
			Request{OnlyIfMissing: true},
			Request{Channel: "stable", Source: core.SourceBuild, DoneKey: "kernel_installed", OnlyIfMissing: true},
		},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			if got := tc.in.Normalize(); got != tc.want {
				t.Fatalf("Normalize(%+v) = %+v, want %+v", tc.in, got, tc.want)
			}
		})
	}
}

// Each of the four channel/source combinations has its own name in the interface.
func TestCombinationKey(t *testing.T) {
	cases := []struct {
		channel string
		source  string
		want    string
	}{
		{"stable", core.SourceBuild, "kernel_stable_author"},
		{"alpha", core.SourceBuild, "kernel_alpha_author"},
		{"stable", core.SourceUpstream, "kernel_stable_official"},
		{"alpha", core.SourceUpstream, "kernel_alpha_official"},
	}
	for _, tc := range cases {
		if got := CombinationKey(tc.channel, tc.source); got != tc.want {
			t.Errorf("CombinationKey(%q, %q) = %q, want %q", tc.channel, tc.source, got, tc.want)
		}
	}
}

// An install request has nothing to do only when the channel *and* the source are the ones
// already installed: comparing channels alone made the way back from the official source a
// no-op.
func TestSame(t *testing.T) {
	cases := []struct {
		name       string
		installed  bool
		haveCh     string
		haveSource string
		wantCh     string
		wantSource string
		want       bool
	}{
		{"author stable already there", true, "stable", core.SourceBuild, "stable", core.SourceBuild, true},
		{"official installed, author wanted", true, "stable", core.SourceUpstream, "stable", core.SourceBuild, false},
		{"author installed, official wanted", true, "stable", core.SourceBuild, "stable", core.SourceUpstream, false},
		{"other channel", true, "stable", core.SourceBuild, "alpha", core.SourceBuild, false},
		{"nothing installed", false, "", core.SourceUpstream, "stable", core.SourceBuild, false},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			got := Same(tc.installed, tc.haveCh, tc.haveSource, tc.wantCh, tc.wantSource)
			if got != tc.want {
				t.Fatalf("Same(%v, %q, %q, %q, %q) = %v, want %v",
					tc.installed, tc.haveCh, tc.haveSource, tc.wantCh, tc.wantSource, got, tc.want)
			}
		})
	}
}

func TestSourceFrom(t *testing.T) {
	cases := []struct {
		recorded string
		stats    bool
		want     string
	}{
		{"build", false, core.SourceBuild},
		{core.SourceUpstream, true, core.SourceUpstream},
		{"", true, core.SourceBuild},
		{"", false, core.SourceUpstream},
	}
	for _, tc := range cases {
		if got := SourceFrom(tc.recorded, tc.stats); got != tc.want {
			t.Errorf("SourceFrom(%q, %v) = %q, want %q", tc.recorded, tc.stats, got, tc.want)
		}
	}
}
