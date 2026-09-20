package tui

import (
	"context"
	"errors"
	"strings"

	tea "charm.land/bubbletea/v2"

	"github.com/MinimaxFlora/EasySB/internal/firewall"
	"github.com/MinimaxFlora/EasySB/internal/i18n"
	"github.com/MinimaxFlora/EasySB/internal/nginx"
	"github.com/MinimaxFlora/EasySB/internal/state"
	"github.com/MinimaxFlora/EasySB/internal/subscribe"
	"github.com/MinimaxFlora/EasySB/internal/uninstall"
	"github.com/MinimaxFlora/EasySB/internal/update"
)

// clientLabel returns the localized menu label for a subscription client.
func clientLabel(lang i18n.Lang, client subscribe.Client) string {
	switch client {
	case subscribe.ClientMihomo:
		return lang.T("sub_client_mihomo")
	case subscribe.ClientV2Ray:
		return lang.T("sub_client_v2ray")
	default:
		return lang.T("sub_client_singbox")
	}
}

// publishSubscription installs nginx when it is missing, renders subscribe.json
// plus the nginx site, and reports the public subscription URL. It is shared by
// node deployment and the manual regenerate action.
func publishSubscription(ctx context.Context, cfg state.Config, log func(string), lang i18n.Lang) error {
	if cfg.Host() == "" {
		log(lang.T("sub_need_domain"))
		return nil
	}
	if err := nginx.Ensure(ctx, log); err != nil {
		return err
	}
	paths, err := subscribe.GenerateFiles(cfg)
	if err != nil {
		return err
	}
	for _, path := range paths {
		log(lang.T("sub_generated") + ": " + path)
	}
	if err := nginx.WriteSite(cfg); err != nil {
		return err
	}
	log(lang.T("svc_nginx_ok"))
	for _, client := range subscribe.Clients {
		log(clientLabel(lang, client) + ": " + subscribe.ClientURL(cfg, client))
	}
	return nil
}

// regenerateSubscription renders subscribe.json and publishes it over nginx.
func regenerateSubscription() actionFunc {
	return func(a *App) tea.Cmd {
		lang := a.lang
		return a.startTask(lang.T("sub_regen"), func(ctx context.Context, log func(string)) error {
			if !hasServerConfig() {
				log(lang.T("sub_need_deploy"))
				return nil
			}
			cfg := state.Load()
			if cfg.Host() == "" {
				return errors.New(lang.T("sub_need_domain"))
			}
			return publishSubscription(ctx, cfg, log, lang)
		})
	}
}

// firewallApply opens ports, installs the hopping redirect and enables boot
// persistence.
func firewallApply() actionFunc {
	return func(a *App) tea.Cmd {
		lang := a.lang
		return a.startTask(lang.T("fw_configuring"), func(ctx context.Context, log func(string)) error {
			cfg := state.Load()
			if !cfg.AnyEnabled() {
				return errors.New(lang.T("node_all_disabled"))
			}
			if err := firewall.Apply(ctx, cfg, log); err != nil {
				return err
			}
			if err := firewall.WriteUnit(cfg); err != nil {
				return err
			}
			if err := firewall.UnitAction(ctx, "enable"); err != nil {
				log("enable unit: " + err.Error())
			}
			log(lang.T("fw_added"))
			return nil
		})
	}
}

// firewallRemove deletes the hopping redirect and its boot unit.
func firewallRemove() actionFunc {
	return func(a *App) tea.Cmd {
		lang := a.lang
		return a.startTask(lang.T("fw_remove"), func(ctx context.Context, log func(string)) error {
			cfg := state.Load()
			if err := firewall.Remove(ctx, cfg); err != nil {
				return err
			}
			if err := firewall.UnitAction(ctx, "disable"); err != nil {
				log("disable unit: " + err.Error())
			}
			if err := firewall.RemoveUnit(); err != nil {
				return err
			}
			log(lang.T("fw_removed"))
			return nil
		})
	}
}

// scriptUpdate downloads and replaces the running binary.
func scriptUpdate() actionFunc {
	return func(a *App) tea.Cmd {
		lang := a.lang
		current := a.scriptVersion
		return a.startTask(lang.T("script_updating"), func(ctx context.Context, log func(string)) error {
			updated, remote, err := update.Apply(ctx, current, log)
			if err != nil {
				return err
			}
			if !updated {
				version := remote
				if version == "" {
					version = current
				}
				log(lang.T("script_uptodate") + ": " + version)
				return nil
			}
			log(lang.T("script_updated") + ": " + remote)
			log(lang.T("script_restart_hint"))
			return nil
		})
	}
}

// uninstallAction asks for confirmation before removing the deployment.
func uninstallAction() actionFunc {
	return func(a *App) tea.Cmd {
		lang := a.lang
		a.openForm(lang.T("uninstall_title"), lang.T("uninstall_confirm")+" (y/N)", "", "", func(a *App, value string) (tea.Cmd, error) {
			switch strings.ToLower(strings.TrimSpace(value)) {
			case "y", "yes":
				return a.startTask(lang.T("uninstall_title"), func(ctx context.Context, log func(string)) error {
					if err := uninstall.Run(ctx, log); err != nil {
						return err
					}
					log(lang.T("uninstall_done"))
					log(lang.T("uninstall_keep_certs"))
					return nil
				}), nil
			default:
				return nil, errors.New(lang.T("cancelled"))
			}
		})
		return nil
	}
}
