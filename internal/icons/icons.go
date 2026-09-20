package icons

import "os"

type Set struct {
	Name     string
	Service  string
	Running  string
	Stopped  string
	Enabled  string
	Disabled string
	Bullet   string
	Arrow    string
	OK       string
	Warn     string
	Err      string
	Info     string
	Core     string
	Globe    string
	Lock     string
	Link     string
	QR       string
	Tool     string
	Rocket   string
	Refresh  string
	Trash    string
	Download string
}

func Plain() Set {
	return Set{
		Name:     "unicode",
		Service:  "◆",
		Running:  "●",
		Stopped:  "○",
		Enabled:  "✓",
		Disabled: "✗",
		Bullet:   "•",
		Arrow:    "▸",
		OK:       "✓",
		Warn:     "⚠",
		Err:      "✗",
		Info:     "ⓘ",
		Core:     "⬢",
		Globe:    "◇",
		Lock:     "▣",
		Link:     "↗",
		QR:       "▦",
		Tool:     "✎",
		Rocket:   "▲",
		Refresh:  "⟳",
		Trash:    "⌫",
		Download: "↓",
	}
}

func Nerd() Set {
	return Set{
		Name:     "nerd",
		Service:  "\uf013",
		Running:  "\uf111",
		Stopped:  "\uf10c",
		Enabled:  "\uf00c",
		Disabled: "\uf00d",
		Bullet:   "\uf0da",
		Arrow:    "\uf054",
		OK:       "\uf00c",
		Warn:     "\uf071",
		Err:      "\uf00d",
		Info:     "\uf05a",
		Core:     "\uf1b2",
		Globe:    "\uf0ac",
		Lock:     "\uf023",
		Link:     "\uf0c1",
		QR:       "\uf029",
		Tool:     "\uf0ad",
		Rocket:   "\uf135",
		Refresh:  "\uf021",
		Trash:    "\uf1f8",
		Download: "\uf019",
	}
}

func Detect() Set {
	switch os.Getenv("EASYSB_ICONS") {
	case "0", "false", "no", "plain":
		return Plain()
	}
	return Nerd()
}
