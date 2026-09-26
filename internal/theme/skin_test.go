package theme

import (
	"fmt"
	"image/color"
	"testing"
)

// TestSkinsAreComplete guards the contract a skin has to satisfy: the switcher
// offers it, both terminal backgrounds are fully colourised, and the geometry is
// sane. A half-filled palette would render as unreadable defaults at runtime,
// which is exactly the kind of mistake a screenshot catches late.
func TestSkinsAreComplete(t *testing.T) {
	all := Skins()
	if len(all) < 3 {
		t.Fatalf("expected several skins, got %d", len(all))
	}

	seen := map[string]bool{}
	for _, s := range all {
		if s.ID == "" || s.Name == "" || s.Note == "" {
			t.Errorf("skin %q is missing id, name or note", s.ID)
		}
		if seen[s.ID] {
			t.Errorf("duplicate skin id %q", s.ID)
		}
		seen[s.ID] = true

		for _, tc := range []struct {
			name string
			pal  Palette
		}{{"dark", s.Dark}, {"light", s.Light}} {
			for field, c := range map[string]color.Color{
				"Primary": tc.pal.Primary, "Accent": tc.pal.Accent, "OK": tc.pal.OK,
				"Warn": tc.pal.Warn, "Err": tc.pal.Err, "Text": tc.pal.Text,
				"Muted": tc.pal.Muted, "TextFaint": tc.pal.TextFaint,
				"Border": tc.pal.Border, "BorderStrong": tc.pal.BorderStrong,
				"Surface": tc.pal.Surface, "SurfaceAlt": tc.pal.SurfaceAlt,
				"SelBg": tc.pal.SelBg, "SelFg": tc.pal.SelFg,
				"GradA": tc.pal.GradA, "GradB": tc.pal.GradB, "BarFg": tc.pal.BarFg,
			} {
				if c == nil || fmt.Sprint(c) == "" {
					t.Errorf("%s %s: %s is unset", s.ID, tc.name, field)
				}
			}
		}
		if s.Dark.IsDark != true || s.Light.IsDark {
			t.Errorf("%s: IsDark is %v/%v, want true/false", s.ID, s.Dark.IsDark, s.Light.IsDark)
		}

		if s.Met.NavWidth < 12 {
			t.Errorf("%s: navigation is %d columns, too narrow to be readable", s.ID, s.Met.NavWidth)
		}
		if s.Met.Gutter < 0 || s.Met.PadX < 0 {
			t.Errorf("%s: negative gutter or padding", s.ID)
		}
	}
}

// TestSkinLettersResolve keeps the a/b/c/d shorthand in step with the order the
// skins are offered in, which is what the switcher prints.
func TestSkinLettersResolve(t *testing.T) {
	for i, s := range Skins() {
		letter := string(rune('a' + i))
		got, ok := SkinByID(letter)
		if !ok {
			t.Fatalf("SkinByID(%q) not found", letter)
		}
		if got.ID != s.ID {
			t.Errorf("SkinByID(%q) = %s, want %s", letter, got.ID, s.ID)
		}
		byID, ok := SkinByID(s.ID)
		if !ok || byID.ID != s.ID {
			t.Errorf("SkinByID(%q) did not resolve the id", s.ID)
		}
	}
	if _, ok := SkinByID(string(rune('a' + len(Skins())))); ok {
		t.Error("a letter past the last skin should not resolve")
	}
	if _, ok := SkinByID("definitely-not-a-skin"); ok {
		t.Error("an unknown id should not resolve")
	}
}

// TestDefaultSkinIsOffered catches the classic drift where DefaultSkin keeps
// returning a look the switcher no longer lists.
func TestDefaultSkinIsOffered(t *testing.T) {
	def := DefaultSkin()
	for _, s := range Skins() {
		if s.ID == def.ID {
			return
		}
	}
	t.Fatalf("default skin %q is not in Skins()", def.ID)
}

// TestStyleCarriesSkinIdentity makes sure a resolved style still knows which look
// it came from, which is what a diagnostics screen prints.
func TestStyleCarriesSkinIdentity(t *testing.T) {
	for _, s := range Skins() {
		if got := s.Style(true); got.ID != s.ID || !got.Dark {
			t.Errorf("%s dark style lost its identity: %+v", s.ID, got)
		}
		if got := s.Style(false); got.ID != s.ID || got.Dark {
			t.Errorf("%s light style lost its identity: %+v", s.ID, got)
		}
	}
}
