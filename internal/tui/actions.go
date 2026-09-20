package tui

import (
	"context"
	"os"
	"os/exec"
	"strings"
	"time"

	tea "charm.land/bubbletea/v2"

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

func simulateKernel(channel string) taskFunc {
	return func(ctx context.Context, log func(string)) error {
		steps := []string{
			"resolve channel: " + channel,
			"query SagerNet/sing-box releases",
			"download core archive",
			"verify checksum",
			"install to " + sysinfo.CoreBin,
			"reload sing-box service",
		}
		for _, s := range steps {
			select {
			case <-ctx.Done():
				return ctx.Err()
			default:
			}
			log("→ " + s)
			time.Sleep(350 * time.Millisecond)
		}
		return nil
	}
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
