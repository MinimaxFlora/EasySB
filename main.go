package main

import (
	"context"
	"flag"
	"fmt"
	"os"
	"os/signal"
	"path/filepath"
	"strings"
	"syscall"
	"time"

	tea "charm.land/bubbletea/v2"

	"github.com/MinimaxFlora/EasySB/internal/config"
	"github.com/MinimaxFlora/EasySB/internal/deploy"
	"github.com/MinimaxFlora/EasySB/internal/firewall"
	"github.com/MinimaxFlora/EasySB/internal/i18n"
	"github.com/MinimaxFlora/EasySB/internal/state"
	"github.com/MinimaxFlora/EasySB/internal/stats"
	"github.com/MinimaxFlora/EasySB/internal/subd"
	"github.com/MinimaxFlora/EasySB/internal/sysinfo"
	"github.com/MinimaxFlora/EasySB/internal/tui"
	"github.com/MinimaxFlora/EasySB/internal/user"
)

var (
	version = "4.0.0"
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
	themeFlag := flag.String("theme", "", "配色方案 / color theme: auto, dark, light")
	showVersion := flag.Bool("version", false, "显示版本 / show version")
	render := flag.Bool("render", false, "渲染一次仪表盘后退出 / render once and exit")
	applyFirewall := flag.Bool("apply-firewall", false, "应用端口跳跃防火墙规则 / apply port-hopping firewall rules")
	serve := flag.Bool("serve", false, "运行订阅服务 / run the subscription service")
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

	if *serve {
		runSubscribeService()
		return
	}

	applyIcons(*iconsFlag)
	applyTheme(*themeFlag)
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

// runSubscribeService serves the subscription endpoint and enforces the account
// policy. It backs the easysb service unit and is the only long-running mode of
// this binary.
func runSubscribeService() {
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()

	logf := func(line string) { fmt.Printf("%s %s\n", time.Now().Format(time.RFC3339), line) }
	logf("EasySB subscription service " + versionLine())

	options := subd.Options{
		Version:      resolveVersion(),
		AccountsPath: sysinfo.UsersFile,
		Dial:         func() (stats.Counter, error) { return stats.Dial(config.StatsListen) },
		Apply: func(ctx context.Context, cfg state.Config, accounts []user.User) error {
			return deploy.Apply(ctx, cfg, accounts)
		},
		Log: logf,
	}
	if err := options.Run(ctx); err != nil {
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

// applyTheme forwards the requested palette to the TUI. An empty or unknown
// value leaves EASYSB_THEME untouched so the TUI keeps auto-detecting.
func applyTheme(mode string) {
	switch strings.ToLower(strings.TrimSpace(mode)) {
	case "auto", "dark", "light":
		_ = os.Setenv("EASYSB_THEME", strings.ToLower(strings.TrimSpace(mode)))
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
