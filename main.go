package main

import (
	"context"
	"flag"
	"fmt"
	"os"
	"path/filepath"
	"strings"

	tea "charm.land/bubbletea/v2"

	"github.com/MinimaxFlora/EasySB/internal/firewall"
	"github.com/MinimaxFlora/EasySB/internal/i18n"
	"github.com/MinimaxFlora/EasySB/internal/state"
	"github.com/MinimaxFlora/EasySB/internal/tui"
)

var (
	version = "3.0.0"
	commit  = ""
)

// versionLine is the human-facing build string, including the short commit when
// the build stamped one.
func versionLine() string {
	v := resolveVersion()
	if len(commit) >= 7 {
		return v + " (" + commit[:7] + ")"
	}
	return v
}

func main() {
	langFlag := flag.String("language", "", "界面语言 / UI language: C (中文) or E (English)")
	iconsFlag := flag.String("icons", "", "图标模式 / icon mode: on, off")
	showVersion := flag.Bool("version", false, "显示版本 / show version")
	render := flag.Bool("render", false, "渲染一次仪表盘后退出 / render once and exit")
	applyFirewall := flag.Bool("apply-firewall", false, "应用端口跳跃防火墙规则 / apply port-hopping firewall rules")
	width := flag.Int("width", 100, "渲染宽度 / render width")
	height := flag.Int("height", 36, "渲染高度 / render height")
	flag.Parse()

	if *showVersion {
		fmt.Printf("EasySB %s\n", versionLine())
		return
	}

	if *applyFirewall {
		runApplyFirewall()
		return
	}

	applyIcons(*iconsFlag)
	lang := i18n.Parse(firstNonEmpty(*langFlag, os.Getenv("EASYSB_LANG")))

	app := tui.New(resolveVersion(), lang)

	if *render {
		fmt.Println(app.Snapshot(*width, *height))
		return
	}

	program := tea.NewProgram(app)
	if _, err := program.Run(); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}

// runApplyFirewall applies the port-hopping rules and exits. It backs the
// easysb-firewall boot unit.
func runApplyFirewall() {
	cfg := state.Load()
	log := func(line string) { fmt.Println(line) }
	if err := firewall.Apply(context.Background(), cfg, log); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
	if err := firewall.WriteUnit(cfg); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}

func applyIcons(mode string) {
	switch strings.ToLower(strings.TrimSpace(mode)) {
	case "on", "1", "true", "yes":
		_ = os.Setenv("EASYSB_ICONS", "1")
	case "off", "0", "false", "no":
		_ = os.Setenv("EASYSB_ICONS", "0")
	}
}

func firstNonEmpty(values ...string) string {
	for _, v := range values {
		if strings.TrimSpace(v) != "" {
			return v
		}
	}
	return ""
}

func resolveVersion() string {
	if v := readVersionFile(); v != "" {
		return v
	}
	return version
}

func readVersionFile() string {
	candidates := []string{
		"/usr/share/easysb/VERSION",
		"VERSION",
	}
	if exe, err := os.Executable(); err == nil {
		candidates = append(candidates, filepath.Join(filepath.Dir(exe), "VERSION"))
	}
	for _, path := range candidates {
		data, err := os.ReadFile(path)
		if err != nil {
			continue
		}
		if v := strings.TrimSpace(string(data)); v != "" {
			return v
		}
	}
	return ""
}
