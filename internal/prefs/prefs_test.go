package prefs

import (
	"os"
	"path/filepath"
	"testing"
)

func TestSaveAndLoadRoundTrip(t *testing.T) {
	path := filepath.Join(t.TempDir(), "nested", "easysb-ui.conf")
	want := Prefs{Skin: "graphite", Theme: "light", Icons: "ascii", Lang: "E"}

	if err := want.Save(path); err != nil {
		t.Fatalf("Save: %v", err)
	}
	if got := Load(path); got != want {
		t.Fatalf("Load = %+v, want %+v", got, want)
	}

	// Saving again replaces the file rather than appending to it.
	want.Skin = "jade"
	want.Theme = ""
	if err := want.Save(path); err != nil {
		t.Fatalf("Save: %v", err)
	}
	if got := Load(path); got != want {
		t.Fatalf("Load after rewrite = %+v, want %+v", got, want)
	}
}

// TestLoadWithoutFileIsNotAnError is the first-run case: the panel has never been
// asked to remember anything, and detection and defaults stay in charge.
func TestLoadWithoutFileIsNotAnError(t *testing.T) {
	got := Load(filepath.Join(t.TempDir(), "missing.conf"))
	if got != (Prefs{}) {
		t.Fatalf("Load of a missing file = %+v, want zero", got)
	}
}

func TestLoadIgnoresNoise(t *testing.T) {
	path := filepath.Join(t.TempDir(), "easysb-ui.conf")
	body := "# EasySB interface preferences\n" +
		"SKIN=\"ember\"\n" +
		"garbage line without separator\n" +
		"THEME=\n" +
		"unknown=\"value\"\n" +
		"LANG=\"E\"\n"
	if err := os.WriteFile(path, []byte(body), 0o644); err != nil {
		t.Fatal(err)
	}
	got := Load(path)
	want := Prefs{Skin: "ember", Lang: "E"}
	if got != want {
		t.Fatalf("Load = %+v, want %+v", got, want)
	}
}

// TestSaveCannotBreakTheFormat matters because the file is on disk and editable: a
// quote or a newline smuggled into a value must not turn into extra lines that the
// next start would read as other choices.
func TestSaveCannotBreakTheFormat(t *testing.T) {
	path := filepath.Join(t.TempDir(), "easysb-ui.conf")
	in := Prefs{Skin: "ember\"\nICONS=\"ascii", Lang: "C"}
	if err := in.Save(path); err != nil {
		t.Fatalf("Save: %v", err)
	}
	got := Load(path)
	if got.Icons != "" {
		t.Fatalf("a quoted newline in a value became a separate setting: %+v", got)
	}
	if got.Skin == "" {
		t.Fatalf("the skin was lost: %+v", got)
	}
}

func TestApplyFillsOnlyUnsetVariables(t *testing.T) {
	saved := Prefs{Skin: "graphite", Theme: "dark", Icons: "ascii", Lang: "E"}
	env := map[string]string{
		// A flag or an exported variable already answered this one.
		SkinEnv: "jade",
	}
	setenv := func(name, value string) error {
		env[name] = value
		return nil
	}
	saved.Apply(func(name string) string { return env[name] }, setenv)

	if env[SkinEnv] != "jade" {
		t.Fatalf("Apply overwrote an explicit choice: %q", env[SkinEnv])
	}
	for name, want := range map[string]string{
		ThemeEnv: "dark",
		IconsEnv: "ascii",
		LangEnv:  "E",
	} {
		if env[name] != want {
			t.Fatalf("Apply left %s = %q, want %q", name, env[name], want)
		}
	}
}

func TestApplySkipsEmptyChoices(t *testing.T) {
	env := map[string]string{}
	Prefs{Skin: "jade"}.Apply(func(name string) string { return env[name] }, func(name, value string) error {
		env[name] = value
		return nil
	})
	if _, ok := env[ThemeEnv]; ok {
		t.Fatal("an unset palette should not be written to the environment")
	}
	if env[SkinEnv] != "jade" {
		t.Fatalf("%s = %q, want jade", SkinEnv, env[SkinEnv])
	}
}

// TestEveryBindingRoundTrips walks the table that Load, Save and Apply all share.
// A field missing from it would be written by nobody and read by nobody, silently.
func TestEveryBindingRoundTrips(t *testing.T) {
	path := filepath.Join(t.TempDir(), "easysb-ui.conf")
	all := Prefs{Skin: "ember", Theme: "light", Icons: "ascii", Lang: "E"}
	if err := all.Save(path); err != nil {
		t.Fatal(err)
	}
	env := map[string]string{}
	Load(path).Apply(func(name string) string { return env[name] }, func(name, value string) error {
		env[name] = value
		return nil
	})
	for _, b := range bindings {
		if env[b.env] != b.get(all) {
			t.Errorf("%s: round trip gave %q, want %q", b.key, env[b.env], b.get(all))
		}
	}
}

func TestPathHonoursOverride(t *testing.T) {
	dir := t.TempDir()
	custom := filepath.Join(dir, "custom.conf")
	t.Setenv(PathEnv, custom)
	if got := Path(); got != custom {
		t.Fatalf("Path() = %q, want %q", got, custom)
	}
	t.Setenv(PathEnv, "")
	if got := Path(); filepath.Base(got) != "easysb-ui.conf" {
		t.Fatalf("Path() = %q, want the panel default", got)
	}
}
