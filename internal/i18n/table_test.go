package i18n

import (
	"strings"
	"testing"
)

// TestTableHasNoDuplicateKeys guards the failure mode the map lookup hides: a
// second entry for the same key silently replaces the first, so a screen keeps
// rendering the wording of a panel that was rewritten or removed.
func TestTableHasNoDuplicateKeys(t *testing.T) {
	seen := make(map[string]int, len(table))
	for i, e := range table {
		if first, ok := seen[e.key]; ok {
			t.Errorf("key %q is defined twice (entries %d and %d)", e.key, first, i)
		}
		seen[e.key] = i
	}
}

// TestTableEntriesAreComplete keeps a half-translated entry from leaking a raw
// key into the interface: T falls back to the key itself, which is exactly what a
// missing translation looks like on screen. An entry whose translation is
// deliberately the key itself is fine here, it is written out on both sides.
func TestTableEntriesAreComplete(t *testing.T) {
	for i, e := range table {
		if strings.TrimSpace(e.key) == "" {
			t.Errorf("entry %d has no key", i)
		}
		for name, value := range map[string]string{"zh": e.cn, "en": e.en} {
			if strings.TrimSpace(value) == "" {
				t.Errorf("entry %d: %s translation is empty for %q", i, name, e.key)
			}
		}
	}
}
