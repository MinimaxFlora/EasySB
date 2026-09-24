// Package icons holds the glyph palette the panel draws with. Every glyph is one
// narrow column wide and comes from the blocks, geometric shapes and arrows that
// terminals ship in their default fonts, so the interface needs no font
// installation and stays aligned on any machine. Plain ASCII stays available as
// an explicit fallback for terminals that cannot render Unicode at all.
package icons

import (
	"os"
	"strings"
)

// Set is the glyph palette for one rendering mode. The field names say what a
// glyph is used for, not which picture it is: a new look replaces the glyphs and
// leaves every call site alone.
type Set struct {
	ID        string
	Host      string
	Service   string
	Running   string
	Stopped   string
	Enabled   string
	Disabled  string
	Bullet    string
	Arrow     string
	OK        string
	Warn      string
	Err       string
	Info      string
	Core      string
	System    string
	Rocket    string
	Globe     string
	Account   string
	Subscribe string
	Link      string
	QR        string
	Tool      string
	Speed     string
	Refresh   string
	Trash     string
	Download  string
}

// Symbols is the default palette: one weight-consistent family of geometric
// shapes, diamonds, arrows and circles that reads clearly in monochrome.
func Symbols() Set {
	return Set{
		ID:        "symbols",
		Host:      "⌂",
		Service:   "⚙",
		Running:   "●",
		Stopped:   "○",
		Enabled:   "✓",
		Disabled:  "✗",
		Bullet:    "•",
		Arrow:     "▸",
		OK:        "✓",
		Warn:      "⚠",
		Err:       "✗",
		Info:      "ⓘ",
		Core:      "⬢",
		System:    "▤",
		Rocket:    "▴",
		Globe:     "◈",
		Account:   "◉",
		Subscribe: "⇅",
		Link:      "↗",
		QR:        "▦",
		Tool:      "✎",
		Speed:     "»",
		Refresh:   "↻",
		Trash:     "⌦",
		Download:  "↓",
	}
}

// ASCII is the fallback for terminals that cannot render Unicode: one printable
// ASCII character per slot, still one column wide.
func ASCII() Set {
	return Set{
		ID:        "ascii",
		Host:      "@",
		Service:   "&",
		Running:   "*",
		Stopped:   ".",
		Enabled:   "+",
		Disabled:  "-",
		Bullet:    "-",
		Arrow:     ">",
		OK:        "+",
		Warn:      "!",
		Err:       "x",
		Info:      "i",
		Core:      "K",
		System:    "#",
		Rocket:    "^",
		Globe:     "D",
		Account:   "U",
		Subscribe: "S",
		Link:      "=",
		QR:        "q",
		Tool:      "t",
		Speed:     "~",
		Refresh:   "R",
		Trash:     "X",
		Download:  "v",
	}
}

// Detect picks the palette from the environment. Only an explicit request for the
// ASCII fallback leaves the Unicode palette; anything else, including the "nerd"
// value older releases documented, gets the default symbols.
func Detect() Set {
	switch strings.ToLower(strings.TrimSpace(os.Getenv("EASYSB_ICONS"))) {
	case "0", "false", "no", "off", "ascii", "none", "plain":
		return ASCII()
	default:
		return Symbols()
	}
}
