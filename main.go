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

	"github.com/MinimaxFlora/EasySB/internal/cert"
	"github.com/MinimaxFlora/EasySB/internal/config"
	"github.com/MinimaxFlora/EasySB/internal/deploy"
	"github.com/MinimaxFlora/EasySB/internal/firewall"
	"github.com/MinimaxFlora/EasySB/internal/i18n"
	"github.com/MinimaxFlora/EasySB/internal/prefs"
	"github.com/MinimaxFlora/EasySB/internal/service"
	"github.com/MinimaxFlora/EasySB/internal/state"
	"github.com/MinimaxFlora/EasySB/internal/stats"
	"github.com/MinimaxFlora/EasySB/internal/subd"
	"github.com/MinimaxFlora/EasySB/internal/sysinfo"
	"github.com/MinimaxFlora/EasySB/internal/tui"
	"github.com/MinimaxFlora/EasySB/internal/user"
)

var (
	version = "4.2.2"
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
	iconsFlag := flag.String("icons", "", "图标方案 / icon set: symbols, ascii (or on, off)")
	themeFlag := flag.String("theme", "", "配色方案 / color theme: auto, dark, light")
	skinFlag := flag.String("skin", "", "界面皮肤 / UI skin: jade, aurora, ember, graphite (or a-d)")
	showVersion := flag.Bool("version", false, "显示版本 / show version")
	render := flag.Bool("render", false, "渲染一次仪表盘后退出 / render once and exit")
	screen := flag.String("screen", "", "配合 --render 渲染指定界面，用栏目 id（kernel/node/domain/bbr…）、system、task 或 bbr-versions / with --render, draw this screen by section id, or system, task, bbr-qdisc, bbr-versions")
	applyFirewall := flag.Bool("apply-firewall", false, "应用端口跳跃防火墙规则 / apply port-hopping firewall rules")
	renewCerts := flag.Bool("renew-certs", false, "续期证书并重载服务（供定时器调用）/ renew certificates and reload the services")
	installTimer := flag.Bool("install-renew-timer", false, "安装证书续期定时器 / install the certificate renewal timer")
	removeTimer := flag.Bool("remove-renew-timer", false, "移除证书续期定时器 / remove the certificate renewal timer")
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

	if *renewCerts {
		runRenewCerts()
		return
	}

	if *installTimer || *removeTimer {
		runRenewTimer(*installTimer)
		return
	}

	if *serve {
		runSubscribeService()
		return
	}

	// Remembered interface choices fill in what the command line left open: a flag
	// or an exported variable still wins, and everything else keeps the choice made
	// from inside the panel.
	prefs.Load(prefs.Path()).Apply(os.Getenv, os.Setenv)

	applyIcons(*iconsFlag)
	applyTheme(*themeFlag)
	applySkin(*skinFlag)
	lang := i18n.Parse(firstNonEmpty(*langFlag, os.Getenv("EASYSB_LANG")))

	app := tui.New(resolveVersion(), lang)

	if *render {
		fmt.Println(app.SnapshotScreen(*screen, *width, *height))
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

// runRenewCerts is the entry point of the renewal timer: it renews what acme.sh
// manages and then reloads the services that hold the old certificate open, so a
// renewal is actually served instead of only stored on disk.
// runRenewTimer installs or removes the renewal timer, the same work the domain
// screen offers. It is a command line mode because the unit names this binary's own
// path, so the binary has to be the thing that writes it: a headless or scripted
// setup has no panel to click, and a unit pointing at some other path renews nothing.
func runRenewTimer(install bool) {
	ctx := context.Background()
	log := func(line string) { fmt.Println(line) }
	if install {
		if err := cert.InstallTimer(ctx, log); err != nil {
			fmt.Fprintln(os.Stderr, err)
			os.Exit(1)
		}
		if next := cert.TimerStatus(); next != "" {
			fmt.Println(next)
		}
		return
	}
	if err := cert.RemoveTimer(ctx, log); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}

func runRenewCerts() {
	ctx := context.Background()
	log := func(line string) { fmt.Println(line) }
	renewed, err := cert.Renew(ctx, log)
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
	// A renewal that changed nothing needs no reload: the core keeps running with
	// the certificate it already has. This timer runs every night, so restarting
	// the services unconditionally would drop every connection once a day.
	if len(renewed) == 0 {
		fmt.Println("no certificate needed renewal")
		return
	}
	// A renewal overwrites the certificate files in place, so nothing in the config
	// on disk changes: only the services that are actually running have to restart
	// to pick the new pair up. Following the running services rather than the
	// deployed flag keeps this correct on a host whose node was deployed outside the
	// panel, where that flag is not set and a renewed certificate would otherwise
	// never be served.
	if service.Active(ctx) {
		if err := service.Do(ctx, "restart"); err != nil {
			fmt.Fprintln(os.Stderr, err)
			os.Exit(1)
		}
	}
	if subd.Active(ctx) {
		if err := subd.Do(ctx, "restart"); err != nil {
			fmt.Fprintln(os.Stderr, err)
			os.Exit(1)
		}
	}
}

// applyIcons forwards the icon mode to the TUI. "on" selects the Unicode symbol
// palette, "off" the ASCII fallback; the legacy "nerd" value behaves like "on".
func applyIcons(mode string) {
	switch strings.ToLower(strings.TrimSpace(mode)) {
	case "on", "1", "true", "yes", "symbols", "unicode", "nerd":
		_ = os.Setenv("EASYSB_ICONS", "symbols")
	case "off", "0", "false", "no", "ascii", "plain":
		_ = os.Setenv("EASYSB_ICONS", "ascii")
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

// applySkin passes the requested look on to the TUI through the environment,
// the same way --theme does. An unknown name is ignored, so the panel falls back
// to the default skin instead of refusing to start.
func applySkin(name string) {
	if strings.TrimSpace(name) == "" {
		return
	}
	_ = os.Setenv("EASYSB_SKIN", strings.TrimSpace(name))
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
