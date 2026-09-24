package subd

import (
	"os"
	"path/filepath"
	"testing"
)

// The subscription unit has to name the installed panel, not whatever copy happens to be
// running. A scratch copy that rewrote it once left the endpoint unable to start when the
// copy was deleted, which takes the subscription down with it.
func TestPickExecutable(t *testing.T) {
	dir := t.TempDir()
	installed := filepath.Join(dir, "easysb")
	scratch := filepath.Join(dir, "easysb-new")
	missing := filepath.Join(dir, "not-there")
	for _, path := range []string{installed, scratch} {
		if err := os.WriteFile(path, []byte("#!/bin/sh\n"), 0o755); err != nil {
			t.Fatalf("write %s: %v", path, err)
		}
	}

	cases := []struct {
		name       string
		self       string
		candidates []string
		want       string
	}{
		{"running from the installed panel", installed, []string{installed}, installed},
		{"running from a scratch copy", scratch, []string{installed}, installed},
		{"nothing installed yet", scratch, []string{missing}, scratch},
		{"self listed among the candidates wins", scratch, []string{missing, installed, scratch}, scratch},
		{"nothing installed and no self", "", []string{missing}, ""},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			if got := pickExecutable(tc.self, tc.candidates); got != tc.want {
				t.Fatalf("pickExecutable(%q, %v) = %q, want %q", tc.self, tc.candidates, got, tc.want)
			}
		})
	}
}
