package tui

import (
	"context"
	"errors"
	"fmt"
	"os"
	"strconv"
	"strings"
	"time"

	tea "charm.land/bubbletea/v2"

	"github.com/MinimaxFlora/EasySB/internal/apps"
	"github.com/MinimaxFlora/EasySB/internal/cert"
	"github.com/MinimaxFlora/EasySB/internal/i18n"
	"github.com/MinimaxFlora/EasySB/internal/service"
	"github.com/MinimaxFlora/EasySB/internal/state"
	"github.com/MinimaxFlora/EasySB/internal/sysinfo"
)

// The camouflage section: real applications served under the operator's domain.
//
// The section exists for one reason: a domain that answers with a working site
// looks like a site, and a domain that answers with nothing looks like a proxy to
// whoever is probing. The panel installs the application, keeps it running, and
// puts its own HTTPS front in front of it — which also serves the subscription
// endpoint, so no part of the deployment needs a bare http:// address:port.

// enterSite opens the section, refreshing the application snapshot first so every
// label in it is a reading rather than a guess.
func enterSite() actionFunc {
	return func(a *App) tea.Cmd {
		a.loadApps()
		a.push(a.siteMenu())
		return nil
	}
}

// loadApps refreshes the per-application reading the section renders from.
func (a *App) loadApps() {
	ctx, cancel := context.WithTimeout(context.Background(), 25*time.Second)
	defer cancel()
	if a.appStatus == nil {
		a.appStatus = map[string]string{}
		a.appVersion = map[string]string{}
	}
	for _, app := range apps.Catalog() {
		a.appStatus[app.ID] = apps.Status(ctx, app)
		a.appVersion[app.ID] = apps.Version(app)
	}
}

// appMark is the one-character state of an application: running, stopped or not
// installed.
func (a *App) appMark(id string) string {
	switch a.appStatus[id] {
	case "running":
		return "●"
	case "stopped":
		return "○"
	default:
		return "·"
	}
}

// appLabel renders one application row: its state, its name and where it is
// listening.
func (a *App) appLabel(app apps.App, l i18n.Lang) string {
	port := apps.Port(state.Load(), app)
	version := a.appVersion[app.ID]
	if version == "" {
		version = l.T("site_no_version")
	}
	return fmt.Sprintf("%s %s · %s :%d · %s", a.appMark(app.ID), app.Name, apps.LocalHost, port, version)
}

// siteMenu is the section's front page.
func (a *App) siteMenu() *menu {
	nodes := []*node{
		{id: "site-status", label: func(l i18n.Lang) string { return a.siteHeadline(l) }, desc: tk("desc_site_status"), action: showSiteStatus()},
		leaf("site-facade", "site_facade", "desc_site_facade", func(a *App) tea.Cmd { a.push(a.facadeMenu()); return nil }),
	}
	for _, app := range apps.Catalog() {
		app := app
		nodes = append(nodes, &node{
			id:     "site-app-" + app.ID,
			label:  func(l i18n.Lang) string { return a.appLabel(app, l) },
			desc:   tk("desc_site_app"),
			action: func(a *App) tea.Cmd { a.push(a.appMenu(app.ID)); return nil },
		})
	}
	nodes = append(nodes,
		leaf("site-log", "site_log", "desc_site_log", showFrontLog()),
	)
	return &menu{id: "site", title: tk("site_title"), nodes: nodes}
}

// siteHeadline is the state line at the top of the section.
func (a *App) siteHeadline(l i18n.Lang) string {
	cfg := state.Load()
	if !cfg.FrontEnabled {
		return l.T("site_off")
	}
	if cfg.FrontApp == "" {
		return l.T("site_no_app")
	}
	app, ok := apps.Lookup(cfg.FrontApp)
	if !ok {
		return l.T("site_no_app")
	}
	target := fmt.Sprintf("https://%s", cfg.Domain)
	return fmt.Sprintf("%s → %s", target, app.Name)
}

// appMenu is one application's own page: install it, run it, read its log, remove
// it.
func (a *App) appMenu(id string) *menu {
	app, ok := apps.Lookup(id)
	if !ok {
		return a.siteMenu()
	}
	title := func(i18n.Lang) string { return app.Name }
	return &menu{id: "site-app-" + id, title: title, nodes: []*node{
		leaf("app-install", "site_install", "desc_site_install", installApp(id)),
		leaf("app-update", "site_update", "desc_site_update", updateApp(id)),
		leaf("app-start", "site_start", "desc_site_start", controlApp(id, "start")),
		leaf("app-stop", "site_stop", "desc_site_stop", controlApp(id, "stop")),
		leaf("app-restart", "site_restart", "desc_site_restart", controlApp(id, "restart")),
		leaf("app-port", "site_port", "desc_site_port", editAppPort(id)),
		leaf("app-logs", "site_logs", "desc_site_logs", showAppLog(id)),
		leaf("app-uninstall", "site_uninstall", "desc_site_uninstall", uninstallApp(id)),
	}}
}

// facadeMenu picks which application the domain serves, and turns the site on or
// off.
func (a *App) facadeMenu() *menu {
	cfg := state.Load()
	nodes := make([]*node, 0, len(apps.Catalog())+3)
	for _, app := range apps.Catalog() {
		app := app
		mark := "[ ]"
		if cfg.FrontApp == app.ID {
			mark = "[x]"
		}
		nodes = append(nodes, &node{
			id:    "facade-" + app.ID,
			label: func(i18n.Lang) string { return mark + " " + app.Name },
			desc:  tk("desc_site_facade_pick"),
			action: func(a *App) tea.Cmd {
				return setFacade(app.ID)(a)
			},
		})
	}
	nodes = append(nodes,
		leaf("facade-on", "site_enable", "desc_site_enable", siteEnable(true)),
		leaf("facade-off", "site_disable", "desc_site_disable", siteEnable(false)),
	)
	return &menu{id: "site-facade", title: tk("site_facade"), nodes: nodes}
}

// showSiteStatus prints the full reading: what is served, on which certificate,
// where the application listens, and whether the unit the front runs in is up.
func showSiteStatus() actionFunc {
	return func(a *App) tea.Cmd {
		lang := a.lang
		return a.startTask(lang.T("site_status"), func(ctx context.Context, r *taskReporter) error {
			cfg := state.Load()
			r.Log(lang.T("site_status_domain") + ": " + orDash(cfg.Domain))
			r.Log(lang.T("site_status_listen") + ": " + orDash(cfg.FrontListen()))
			if cfg.FrontApp == "" {
				r.Log(lang.T("site_status_app") + ": " + lang.T("site_no_app"))
			} else if app, ok := apps.Lookup(cfg.FrontApp); ok {
				r.Log(lang.T("site_status_app") + ": " + app.Name + " (" + app.WebURL(apps.Port(cfg, app)) + ")")
			}
			fullchain, key, ok := cert.Paths(cfg.Domain)
			if ok {
				r.Log(lang.T("site_status_cert") + ": " + fullchain + " + " + key)
			} else {
				r.Log(lang.T("site_status_cert") + ": " + lang.T("site_need_cert"))
			}
			active := service.Active(ctx)
			state := lang.T("site_status_panel_down")
			if active {
				state = lang.T("site_status_panel_up")
			}
			r.Log(lang.T("site_status_panel") + ": " + state)
			r.Log("$ " + service.Command("status"))
			out, _ := runCmd(ctx, "systemctl", "status", sysinfo.SubServiceName, "--no-pager")
			emit(r.Log, out)
			for _, app := range apps.Catalog() {
				r.Log(fmt.Sprintf("%s: %s · %s", app.Name, apps.Status(ctx, app), apps.Version(app)))
			}
			return nil
		})
	}
}

// installApp downloads the newest release, verifies it and starts the service.
func installApp(id string) actionFunc {
	return func(a *App) tea.Cmd {
		app, ok := apps.Lookup(id)
		if !ok {
			return nil
		}
		lang := a.lang
		cfg := state.Load()
		return a.startTask(lang.T("site_installing")+" · "+app.Name, func(ctx context.Context, r *taskReporter) error {
			port := apps.Port(cfg, app)
			if !apps.PortFree(port) {
				return fmt.Errorf("%s: %s", lang.T("site_port_busy"), fmt.Sprintf("127.0.0.1:%d", port))
			}
			if _, err := apps.Install(ctx, apps.Request{
				App:      app,
				Port:     port,
				Domain:   cfg.Domain,
				Log:      r.Log,
				Progress: func(done, total int64) { r.Progress(app.Name, done, total) },
			}); err != nil {
				return err
			}
			r.Log("")
			r.Log(fmt.Sprintf(lang.T("site_installed"), app.Name, app.WebURL(port)))
			return nil
		})
	}
}

// updateApp installs the newest release unless the installed one already is it.
func updateApp(id string) actionFunc {
	return func(a *App) tea.Cmd {
		app, ok := apps.Lookup(id)
		if !ok {
			return nil
		}
		lang := a.lang
		cfg := state.Load()
		return a.startTask(lang.T("site_updating")+" · "+app.Name, func(ctx context.Context, r *taskReporter) error {
			changed, version, err := apps.Update(ctx, apps.Request{
				App:      app,
				Port:     apps.Port(cfg, app),
				Domain:   cfg.Domain,
				Log:      r.Log,
				Progress: func(done, total int64) { r.Progress(app.Name, done, total) },
			})
			if err != nil {
				return err
			}
			if !changed {
				r.Log(fmt.Sprintf(lang.T("site_up_to_date"), app.Name, version))
			}
			return nil
		})
	}
}

// controlApp starts, stops or restarts an application.
func controlApp(id, verb string) actionFunc {
	return func(a *App) tea.Cmd {
		app, ok := apps.Lookup(id)
		if !ok {
			return nil
		}
		lang := a.lang
		return a.startTask(lang.T("site_"+verb)+" · "+app.Name, func(ctx context.Context, r *taskReporter) error {
			if !apps.Installed(app) {
				return errors.New(fmt.Sprintf(lang.T("site_not_installed"), app.Name))
			}
			if err := apps.Control(ctx, app, verb); err != nil {
				return err
			}
			r.Log(lang.T("ok"))
			if verb == "start" || verb == "restart" {
				r.Log(fmt.Sprintf(lang.T("site_installed"), app.Name, app.WebURL(apps.Port(state.Load(), app))))
			}
			return nil
		})
	}
}

// editAppPort changes the loopback port an application listens on and restarts
// it, so the front's target and the application agree.
func editAppPort(id string) actionFunc {
	return func(a *App) tea.Cmd {
		app, ok := apps.Lookup(id)
		if !ok {
			return nil
		}
		lang := a.lang
		current := apps.Port(state.Load(), app)
		prompt := fmt.Sprintf(lang.T("site_port_prompt"), app.Name, apps.LocalHost)
		a.openForm(lang.T("site_port"), prompt, strconv.Itoa(current), "", func(a *App, value string) (tea.Cmd, error) {
			port, err := strconv.Atoi(strings.TrimSpace(value))
			if err != nil || port < 1 || port > 65535 {
				return nil, errors.New(lang.T("port_invalid"))
			}
			if port != current && !apps.PortFree(port) {
				return nil, errors.New(lang.T("site_port_busy"))
			}
			cfg := state.Load()
			cfg.SetAppPort(app.ID, port)
			if err := cfg.Save(); err != nil {
				return nil, err
			}
			if !apps.Installed(app) {
				a.setToast(lang.T("node_params_saved"), false)
				return nil, nil
			}
			// The service unit carries the port, so it has to be rewritten and the
			// service restarted for the change to take effect.
			return a.startTask(lang.T("site_port")+" · "+app.Name, func(ctx context.Context, r *taskReporter) error {
				if err := apps.RewriteUnit(ctx, app, port, cfg.Domain); err != nil {
					return err
				}
				r.Log(fmt.Sprintf(lang.T("site_port_changed"), apps.LocalHost, port))
				return nil
			}), nil
		})
		return nil
	}
}

// uninstallApp removes the application after showing exactly what it removes: the
// service definition and the application's own directory, which holds its data.
func uninstallApp(id string) actionFunc {
	return func(a *App) tea.Cmd {
		app, ok := apps.Lookup(id)
		if !ok {
			return nil
		}
		lang := a.lang
		confirm := fmt.Sprintf(lang.T("site_uninstall_confirm"), app.UnitPath(), app.Dir())
		a.openForm(lang.T("site_uninstall")+" · "+app.Name, confirm, "", "y/N", func(a *App, value string) (tea.Cmd, error) {
			switch strings.ToLower(strings.TrimSpace(value)) {
			case "y", "yes":
				return a.startTask(lang.T("site_uninstall")+" · "+app.Name, func(ctx context.Context, r *taskReporter) error {
					removed, err := apps.Uninstall(ctx, app, r.Log)
					for _, path := range removed {
						r.Log(lang.T("site_removed") + " " + path)
					}
					return err
				}), nil
			default:
				return nil, errors.New(lang.T("cancelled"))
			}
		})
		return nil
	}
}

// setFacade points the domain at an application and restarts the panel service,
// which is the process that serves the site.
func setFacade(id string) actionFunc {
	return func(a *App) tea.Cmd {
		app, ok := apps.Lookup(id)
		if !ok {
			return nil
		}
		lang := a.lang
		cfg := state.Load()
		return a.startTask(lang.T("site_facade")+" · "+app.Name, func(ctx context.Context, r *taskReporter) error {
			if strings.TrimSpace(cfg.Domain) == "" {
				return errors.New(lang.T("site_need_domain"))
			}
			if _, _, ok := cert.Paths(cfg.Domain); !ok {
				return errors.New(lang.T("site_need_cert"))
			}
			if !apps.Installed(app) {
				return errors.New(fmt.Sprintf(lang.T("site_not_installed"), app.Name))
			}
			if !apps.Active(ctx, app) {
				if err := apps.Control(ctx, app, "start"); err != nil {
					return err
				}
			}
			cfg.FrontApp = app.ID
			cfg.FrontEnabled = true
			if err := cfg.Save(); err != nil {
				return err
			}
			r.Log("$ " + service.CommandFor(sysinfo.SubServiceName, "restart"))
			if err := service.DoFor(ctx, sysinfo.SubServiceName, "restart"); err != nil {
				return err
			}
			r.Log(fmt.Sprintf(lang.T("site_on"), cfg.Domain, app.Name))
			return nil
		})
	}
}

// siteEnable turns the camouflage site on or off. Turning it off leaves the
// application installed and running: only the site goes away.
func siteEnable(on bool) actionFunc {
	return func(a *App) tea.Cmd {
		lang := a.lang
		title := lang.T("site_disable")
		if on {
			title = lang.T("site_enable")
		}
		return a.startTask(title, func(ctx context.Context, r *taskReporter) error {
			cfg := state.Load()
			if on {
				if cfg.FrontApp == "" {
					return errors.New(lang.T("site_no_app"))
				}
				if strings.TrimSpace(cfg.Domain) == "" {
					return errors.New(lang.T("site_need_domain"))
				}
				if _, _, ok := cert.Paths(cfg.Domain); !ok {
					return errors.New(lang.T("site_need_cert"))
				}
			}
			cfg.FrontEnabled = on
			if err := cfg.Save(); err != nil {
				return err
			}
			r.Log("$ " + service.CommandFor(sysinfo.SubServiceName, "restart"))
			if err := service.DoFor(ctx, sysinfo.SubServiceName, "restart"); err != nil {
				return err
			}
			if on {
				r.Log(fmt.Sprintf(lang.T("site_on"), cfg.Domain, cfg.FrontApp))
			} else {
				r.Log(lang.T("site_off"))
			}
			return nil
		})
	}
}

// showAppLog prints an application's own log, which is where it prints the
// password it generated for its first login.
func showAppLog(id string) actionFunc {
	return func(a *App) tea.Cmd {
		app, ok := apps.Lookup(id)
		if !ok {
			return nil
		}
		lang := a.lang
		return a.startTask(lang.T("site_logs")+" · "+app.Name, func(ctx context.Context, r *taskReporter) error {
			logs := apps.Logs(ctx, app, 60)
			if strings.TrimSpace(logs) == "" {
				r.Log(lang.T("site_no_logs"))
				return nil
			}
			for _, line := range strings.Split(strings.TrimRight(logs, "\n"), "\n") {
				r.Log(line)
			}
			return nil
		})
	}
}

// showFrontLog prints the access log: the line an operator reads to tell a real
// visitor from a scanner.
func showFrontLog() actionFunc {
	return func(a *App) tea.Cmd {
		lang := a.lang
		return a.startTask(lang.T("site_log"), func(ctx context.Context, r *taskReporter) error {
			body, err := os.ReadFile(sysinfo.FrontLogFile)
			if err != nil || strings.TrimSpace(string(body)) == "" {
				r.Log(lang.T("site_no_logs"))
				return nil
			}
			lines := strings.Split(strings.TrimRight(string(body), "\n"), "\n")
			if len(lines) > 120 {
				lines = lines[len(lines)-120:]
			}
			for _, line := range lines {
				r.Log(line)
			}
			return nil
		})
	}
}

func orDash(v string) string {
	if strings.TrimSpace(v) == "" {
		return "-"
	}
	return v
}
