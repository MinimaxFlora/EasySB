package tui

import (
	"context"
	"errors"
	"os"
	"os/exec"
	"strings"

	tea "charm.land/bubbletea/v2"

	"github.com/MinimaxFlora/EasySB/internal/cert"
	"github.com/MinimaxFlora/EasySB/internal/config"
	"github.com/MinimaxFlora/EasySB/internal/core"
	"github.com/MinimaxFlora/EasySB/internal/netutil"
	"github.com/MinimaxFlora/EasySB/internal/secret"
	"github.com/MinimaxFlora/EasySB/internal/service"
	"github.com/MinimaxFlora/EasySB/internal/state"
	"github.com/MinimaxFlora/EasySB/internal/subscribe"
	"github.com/MinimaxFlora/EasySB/internal/sysinfo"
)

func serviceAction(verb string) actionFunc {
	return func(a *App) tea.Cmd {
		title := a.lang.T("svc_title") + " · " + verb
		lang := a.lang
		fn := func(ctx context.Context, log func(string)) error {
			switch verb {
			case "status":
				log("$ systemctl status " + sysinfo.ServiceName + " --no-pager")
				out, _ := runCmd(ctx, "systemctl", "status", sysinfo.ServiceName, "--no-pager")
				emit(log, out)
				out2, _ := runCmd(ctx, "systemctl", "is-enabled", sysinfo.ServiceName)
				emit(log, out2)
				return nil
			default:
				log("$ systemctl " + verb + " " + sysinfo.ServiceName)
				out, err := runCmd(ctx, "systemctl", verb, sysinfo.ServiceName)
				emit(log, out)
				if err != nil {
					return err
				}
				log(lang.T("ok"))
				return nil
			}
		}
		return a.startTask(title, fn)
	}
}

// kernelAction installs, switches or updates the sing-box core. The channel
// argument is "stable", "alpha" or "current" (update the installed channel).
func kernelAction(channel string) actionFunc {
	return func(a *App) tea.Cmd {
		lang := a.lang
		return a.startTask(lang.T("kernel_installing"), func(ctx context.Context, log func(string)) error {
			cfg := state.Load()
			target := channel
			if channel == "current" {
				if !core.Installed() {
					return errors.New(lang.T("svc_not_installed"))
				}
				target = core.InstalledChannel(cfg.CoreChannel)
			} else if core.Installed() && core.InstalledChannel(cfg.CoreChannel) == channel {
				log(lang.T("kernel_already") + ": " + lang.T(channelKey(channel)))
				return nil
			}

			rels, err := core.FetchReleases(ctx)
			if err != nil {
				log(lang.T("ver_offline"))
			}
			rel := rels.Stable
			if target == "alpha" {
				rel = rels.Alpha
			}
			if rel.Version == "" {
				return errors.New(lang.T("kernel_no_version"))
			}

			if core.Installed() {
				log("$ systemctl stop " + sysinfo.ServiceName)
				runCmd(ctx, "systemctl", "stop", sysinfo.ServiceName)
			}

			log(lang.T("kernel_downloading") + ": " + target + " " + rel.Version)
			version, err := core.Install(ctx, rel, log)
			if err != nil {
				return err
			}

			cfg.CoreChannel = target
			if err := cfg.Save(); err != nil {
				return err
			}

			if hasServerConfig() {
				log("$ systemctl start " + sysinfo.ServiceName)
				runCmd(ctx, "systemctl", "start", sysinfo.ServiceName)
			}
			if channel == "current" {
				log(lang.T("kernel_updated") + ": " + version)
			} else {
				log(lang.T("kernel_installed") + ": " + lang.T(channelKey(target)) + " " + version)
			}
			return nil
		})
	}
}

func hasServerConfig() bool {
	info, err := os.Stat(sysinfo.ConfigJSON)
	return err == nil && info.Size() > 0
}

// renderConfig resolves the active certificate and renders config.json bytes.
func renderConfig(cfg state.Config) ([]byte, error) {
	pair, err := cert.ResolveActive(cfg.Domain)
	if err != nil {
		return nil, err
	}
	params := config.ParamsFromState(cfg)
	params.CertFullchain = pair.Fullchain
	params.CertKey = pair.Key
	return config.Build(params)
}

// writeConfig renders and writes config.json to the working directory.
func writeConfig(cfg state.Config) error {
	data, err := renderConfig(cfg)
	if err != nil {
		return err
	}
	if err := os.MkdirAll(sysinfo.WorkDir, 0o755); err != nil {
		return err
	}
	return os.WriteFile(sysinfo.ConfigJSON, data, 0o644)
}

func showSubscriptionURL() actionFunc {
	return func(a *App) tea.Cmd {
		lang := a.lang
		return a.startTask(lang.T("sub_url"), func(ctx context.Context, log func(string)) error {
			cfg := state.Load()
			if cfg.Host() == "" {
				log(lang.T("sub_need_domain"))
				return nil
			}
			log(subscribe.URL(cfg))
			return nil
		})
	}
}

func showSubscriptionQR() actionFunc {
	return func(a *App) tea.Cmd {
		lang := a.lang
		return a.startTask(lang.T("sub_qr"), func(ctx context.Context, log func(string)) error {
			cfg := state.Load()
			if cfg.Host() == "" {
				log(lang.T("sub_need_domain"))
				return nil
			}
			payload := subscribe.DeepLink(subscribe.URL(cfg))
			log(lang.T("sub_qr_payload") + ":")
			log(payload)
			log("")
			qr, err := subscribe.QRCode(payload)
			if err != nil {
				log(lang.T("sub_no_qrencode"))
				return nil
			}
			for _, line := range strings.Split(qr, "\n") {
				log(line)
			}
			return nil
		})
	}
}

func showShareLinks() actionFunc {
	return func(a *App) tea.Cmd {
		lang := a.lang
		return a.startTask(lang.T("sub_links"), func(ctx context.Context, log func(string)) error {
			cfg := state.Load()
			if !cfg.AnyEnabled() {
				log(lang.T("node_all_disabled"))
				return nil
			}
			for _, line := range subscribe.ShareLinks(cfg) {
				log(line)
			}
			return nil
		})
	}
}

// deployNode generates config.json, installs the service unit and starts the
// node, auto-filling any missing credentials.
func deployNode() actionFunc {
	return func(a *App) tea.Cmd {
		lang := a.lang
		return a.startTask(lang.T("node_deploying"), func(ctx context.Context, log func(string)) error {
			if !core.Installed() {
				return errors.New(lang.T("node_need_core"))
			}
			cfg := state.Load()
			if !cfg.AnyEnabled() {
				return errors.New(lang.T("node_all_disabled"))
			}

			if cfg.UUID == "" {
				cfg.UUID = core.GenerateUUID(ctx)
				log(lang.T("param_uuid_gen") + ": " + cfg.UUID)
			}
			if cfg.Password == "" {
				cfg.Password = secret.Password()
				log(lang.T("param_pw_gen"))
			}
			if cfg.Enabled[state.ProtoVLESSReality] {
				if cfg.RealityPriv == "" || cfg.RealityPub == "" {
					priv, pub, err := core.RealityKeypair(ctx)
					if err != nil {
						return err
					}
					cfg.RealityPriv, cfg.RealityPub = priv, pub
					log(lang.T("param_key_gen"))
				}
				if cfg.RealitySID == "" {
					cfg.RealitySID = secret.ShortID()
				}
			}

			if cfg.Domain == "" && cfg.CertDomain != "" {
				cfg.Domain = cfg.CertDomain
			}
			if cfg.Domain == "" && config.ParamsFromState(cfg).NeedsCert() {
				log(lang.T("node_need_domain"))
				log("→ self-signed placeholder certificate")
			}

			if cfg.ServerIP == "" && cfg.Domain == "" {
				if ip, err := netutil.PublicIP(ctx); err == nil {
					cfg.ServerIP = ip
					log("server ip: " + ip)
				}
			}

			if err := writeConfig(cfg); err != nil {
				return err
			}
			log("write " + sysinfo.ConfigJSON)

			if !core.ConfigCheck(ctx, sysinfo.ConfigJSON) {
				return errors.New(lang.T("node_config_fail"))
			}
			log(lang.T("node_config_ok"))

			if err := cfg.Save(); err != nil {
				return err
			}
			if err := service.WriteUnit(); err != nil {
				return err
			}
			log("write " + service.UnitPath())
			if err := service.Do(ctx, "enable"); err != nil {
				log("enable: " + err.Error())
			}
			if err := service.Do(ctx, "restart"); err != nil {
				return err
			}

			cfg.NodeDeployed = true
			if err := cfg.Save(); err != nil {
				return err
			}
			log(lang.T("node_deploy_done"))
			return nil
		})
	}
}

func runCmd(ctx context.Context, name string, args ...string) (string, error) {
	cmd := exec.CommandContext(ctx, name, args...)
	cmd.Env = append(os.Environ(), "LC_ALL=C")
	out, err := cmd.CombinedOutput()
	return string(out), err
}

func emit(log func(string), out string) {
	out = strings.TrimRight(out, "\n")
	if out == "" {
		return
	}
	for _, line := range strings.Split(out, "\n") {
		log(line)
	}
}
