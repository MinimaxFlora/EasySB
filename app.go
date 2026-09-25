package main

import (
	"context"
	"flag"
	"fmt"
	"net/http"
	"os"
	"strconv"
	"strings"
	"time"

	"github.com/MinimaxFlora/EasySB/internal/apps"
	"github.com/MinimaxFlora/EasySB/internal/cert"
	"github.com/MinimaxFlora/EasySB/internal/front"
	"github.com/MinimaxFlora/EasySB/internal/service"
	"github.com/MinimaxFlora/EasySB/internal/state"
	"github.com/MinimaxFlora/EasySB/internal/sysinfo"
)

// runAppCommand is the command line side of the camouflage applications. The
// panel drives the same code from its own screens; this entry point exists so a
// deployment can be scripted, and so the operations can be run over ssh without
// opening the TUI.
//
//	easysb app list
//	easysb app install|update|uninstall|start|stop|restart|status|port|logs <id> [flags]
//	easysb app site <id>|off              serve the domain to an application
//	easysb app front on|off               turn the camouflage site on or off
func runAppCommand(args []string) {
	if len(args) == 0 {
		fmt.Fprintln(os.Stderr, appUsage)
		os.Exit(2)
	}
	action := args[0]
	rest := args[1:]

	switch action {
	case "list":
		ctx := context.Background()
		cfg := state.Load()
		for _, a := range apps.Catalog() {
			fmt.Printf("%-10s %-18s %-14s port=%-6d %s\n",
				a.ID, a.Name, apps.Status(ctx, a), apps.Port(cfg, a), a.Note)
		}
		fmt.Printf("front: enabled=%v app=%q port=%d domain=%q cert=%v\n",
			cfg.FrontEnabled, cfg.FrontApp, cfg.FrontPort, cfg.Domain, frontReady(cfg))
		return
	case "site", "front":
		runAppSite(action, rest)
		return
	}

	if len(rest) == 0 {
		fmt.Fprintln(os.Stderr, appUsage)
		os.Exit(2)
	}
	id := rest[0]
	a, ok := apps.Lookup(id)
	if !ok {
		fmt.Fprintf(os.Stderr, "unknown application %q (try: %s)\n", id, strings.Join(apps.IDs(), ", "))
		os.Exit(2)
	}

	flags := flag.NewFlagSet("app", flag.ExitOnError)
	port := flags.Int("port", 0, "listen port")
	version := flags.String("version", "", "release tag to install")
	force := flags.Bool("force", false, "reinstall even when the version already matches")
	flags.Parse(rest[1:])

	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Minute)
	defer cancel()

	cfg := state.Load()
	if *port > 0 {
		cfg.SetAppPort(a.ID, *port)
		if err := cfg.Save(); err != nil {
			fmt.Fprintln(os.Stderr, err)
			os.Exit(1)
		}
	}
	listen := apps.Port(cfg, a)

	logf := func(line string) { fmt.Printf("%s %s\n", time.Now().Format(time.RFC3339), line) }
	progress := func(done, total int64) {
		if total > 0 {
			fmt.Printf("\r  %d/%d MB", done>>20, total>>20)
			return
		}
		fmt.Printf("\r  %d MB", done>>20)
	}
	finishProgress := func() { fmt.Print("\r\033[K") }

	req := apps.Request{App: a, Version: *version, Port: listen, Domain: cfg.Domain, Force: *force, Log: logf, Progress: progress}

	switch action {
	case "install":
		version, err := apps.Install(ctx, req)
		finishProgress()
		if err != nil {
			fmt.Fprintln(os.Stderr, err)
			os.Exit(1)
		}
		fmt.Printf("%s %s installed on %s\n", a.Name, version, a.WebURL(listen))
	case "update":
		changed, version, err := apps.Update(ctx, req)
		finishProgress()
		if err != nil {
			fmt.Fprintln(os.Stderr, err)
			os.Exit(1)
		}
		fmt.Printf("%s %s changed=%v\n", a.Name, version, changed)
	case "uninstall":
		removed, err := apps.Uninstall(ctx, a, logf)
		if err != nil {
			fmt.Fprintln(os.Stderr, err)
			os.Exit(1)
		}
		for _, path := range removed {
			fmt.Println("removed " + path)
		}
	case "start", "stop", "restart", "enable", "disable":
		if err := apps.Control(ctx, a, action); err != nil {
			fmt.Fprintln(os.Stderr, err)
			os.Exit(1)
		}
		fmt.Printf("%s %s ok\n", a.Name, action)
	case "status":
		fmt.Printf("%s: %s on %s (version %s)\n", a.ID, apps.Status(ctx, a), a.WebURL(listen), apps.Version(a))
	case "logs":
		fmt.Println(apps.Logs(ctx, a, 60))
	case "port":
		fmt.Println(listen)
	default:
		fmt.Fprintln(os.Stderr, appUsage)
		os.Exit(2)
	}
}

// runAppSite turns the camouflage site on: `site <id>` serves the domain to that
// application, `site off` only turns the site off and leaves the application
// installed.
func runAppSite(action string, rest []string) {
	if len(rest) == 0 {
		fmt.Fprintln(os.Stderr, appUsage)
		os.Exit(2)
	}
	cfg := state.Load()
	target := rest[0]

	if target == "off" || (action == "front" && target == "off") {
		cfg.FrontEnabled = false
		if err := cfg.Save(); err != nil {
			fmt.Fprintln(os.Stderr, err)
			os.Exit(1)
		}
		_ = service.DoFor(context.Background(), sysinfo.SubServiceName, "restart")
		fmt.Println("camouflage site off")
		return
	}
	a, ok := apps.Lookup(target)
	if !ok {
		fmt.Fprintf(os.Stderr, "unknown application %q (try: %s)\n", target, strings.Join(apps.IDs(), ", "))
		os.Exit(2)
	}
	if strings.TrimSpace(cfg.Domain) == "" {
		fmt.Fprintln(os.Stderr, "no domain set: the site is served over https on the domain, so set one first")
		os.Exit(1)
	}
	if _, _, ok := cert.Paths(cfg.Domain); !ok {
		fmt.Fprintf(os.Stderr, "no certificate for %s yet: issue one from the panel first\n", cfg.Domain)
		os.Exit(1)
	}
	if !apps.Installed(a) {
		fmt.Fprintf(os.Stderr, "%s is not installed yet\n", a.ID)
		os.Exit(1)
	}
	if !apps.Active(context.Background(), a) {
		fmt.Fprintf(os.Stderr, "%s is not running\n", a.ID)
		os.Exit(1)
	}

	cfg.FrontApp = a.ID
	cfg.FrontEnabled = true
	if err := cfg.Save(); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
	if err := service.DoFor(context.Background(), sysinfo.SubServiceName, "restart"); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
	fmt.Printf("camouflage site on: https://%s -> %s (%s)\n", cfg.Domain, a.WebURL(apps.Port(cfg, a)), a.Name)
}

// frontReady reports whether the front has what it needs to serve the site.
func frontReady(cfg state.Config) bool {
	if !cfg.FrontEnabled || cfg.FrontApp == "" {
		return false
	}
	if _, _, ok := cert.Paths(cfg.Domain); !ok {
		return false
	}
	_, ok := apps.Lookup(cfg.FrontApp)
	return ok
}

// frontOptions builds the front's options from the state, or reports why the site
// cannot be served.
func frontOptions(cfg state.Config, subSub http.Handler) (front.Options, bool) {
	if !cfg.FrontEnabled {
		return front.Options{}, false
	}
	a, ok := apps.Lookup(cfg.FrontApp)
	if !ok {
		return front.Options{}, false
	}
	fullchain, key, ok := cert.Paths(cfg.Domain)
	if !ok {
		return front.Options{}, false
	}
	return front.Options{
		Listen:    cfg.FrontListen(),
		Domain:    cfg.Domain,
		CertFile:  fullchain,
		KeyFile:   key,
		App:       a.Name,
		AppTarget: "127.0.0.1:" + strconv.Itoa(apps.Port(cfg, a)),
		Sub:       subSub,
		LogFile:   sysinfo.FrontLogFile,
	}, true
}

// appUsage is the help text for the app subcommand.
const appUsage = `usage:
  easysb app list
  easysb app install|update|uninstall|start|stop|restart|status|logs|port <id> [--port N] [--version TAG] [--force]
  easysb app site <id>|off`
