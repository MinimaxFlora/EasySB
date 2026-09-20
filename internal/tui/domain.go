package tui

import (
	"context"
	"errors"
	"strings"

	tea "charm.land/bubbletea/v2"

	"github.com/MinimaxFlora/EasySB/internal/cert"
	"github.com/MinimaxFlora/EasySB/internal/core"
	"github.com/MinimaxFlora/EasySB/internal/i18n"
	"github.com/MinimaxFlora/EasySB/internal/netutil"
	"github.com/MinimaxFlora/EasySB/internal/service"
	"github.com/MinimaxFlora/EasySB/internal/state"
	"github.com/MinimaxFlora/EasySB/internal/sysinfo"
)

// issueCertAction collects the acme email (when needed) and domain, then issues
// a certificate in a background task.
func issueCertAction() actionFunc {
	return func(a *App) tea.Cmd {
		lang := a.lang

		startDomainPrompt := func(email string) {
			a.openForm(lang.T("domain_issue"), lang.T("domain_prompt"), "", "", func(a *App, value string) (tea.Cmd, error) {
				domain := strings.TrimSpace(value)
				if domain == "" {
					return nil, errors.New(lang.T("cancelled"))
				}
				return a.startTask(lang.T("domain_issuing"), issueCertTask(lang, email, domain)), nil
			})
		}

		if cert.ACMEInstalled() {
			startDomainPrompt("")
			return nil
		}
		a.openForm(lang.T("domain_email"), lang.T("domain_email"), "", "", func(a *App, value string) (tea.Cmd, error) {
			email := strings.TrimSpace(value)
			if email == "" {
				return nil, errors.New(lang.T("domain_email_required"))
			}
			startDomainPrompt(email)
			return nil, nil
		})
		return nil
	}
}

func issueCertTask(lang i18n.Lang, email, domain string) taskFunc {
	return func(ctx context.Context, log func(string)) error {
		if !cert.ACMEInstalled() {
			log(lang.T("domain_installing_acme"))
			if err := cert.EnsureACME(ctx, email, log); err != nil {
				return err
			}
		}

		cfg := state.Load()
		if cfg.ServerIP == "" {
			if ip, err := netutil.PublicIP(ctx); err == nil {
				cfg.ServerIP = ip
			}
		}

		// Temporarily stop sing-box so the standalone challenge can bind 80.
		stopped := service.Active(ctx)
		if stopped {
			log("$ systemctl stop " + sysinfo.ServiceName)
			_ = service.Do(ctx, "stop")
		}
		issueErr := cert.Issue(ctx, domain, log)
		if stopped && hasServerConfig() {
			log("$ systemctl start " + sysinfo.ServiceName)
			_ = service.Do(ctx, "start")
		}
		if issueErr != nil {
			return issueErr
		}
		if _, _, ok := cert.Paths(domain); !ok {
			return errors.New(lang.T("domain_issue_failed"))
		}

		cfg.Domain = domain
		cfg.CertDomain = domain
		if err := cfg.Save(); err != nil {
			return err
		}
		log(lang.T("domain_issued") + ": " + domain)

		if cfg.NodeDeployed && core.Installed() {
			if err := writeConfig(cfg); err != nil {
				return err
			}
			if err := service.Do(ctx, "restart"); err != nil {
				return err
			}
			log(lang.T("domain_applied"))
		}
		return nil
	}
}

// listCerts pushes a dynamic menu listing the certificates found on disk.
func listCerts() actionFunc {
	return func(a *App) tea.Cmd {
		domains := cert.Domains()
		if len(domains) == 0 {
			a.setToast(a.lang.T("domain_empty"), true)
			return nil
		}
		a.push(certMenu("domain-active", domains, switchCert))
		return nil
	}
}

// switchCertAction pushes a menu for choosing the active certificate.
func switchCertAction() actionFunc {
	return func(a *App) tea.Cmd {
		domains := cert.Domains()
		if len(domains) == 0 {
			a.setToast(a.lang.T("domain_empty"), true)
			return nil
		}
		a.push(certMenu("domain-switch", domains, switchCert))
		return nil
	}
}

// removeCertAction pushes a menu for choosing a certificate to delete.
func removeCertAction() actionFunc {
	return func(a *App) tea.Cmd {
		domains := cert.Domains()
		if len(domains) == 0 {
			a.setToast(a.lang.T("domain_empty"), true)
			return nil
		}
		a.push(certMenu("domain-remove", domains, confirmRemoveCert))
		return nil
	}
}

func switchCert(a *App, domain string) tea.Cmd {
	lang := a.lang
	cfg := state.Load()
	cfg.Domain = domain
	cfg.CertDomain = domain
	if err := cfg.Save(); err != nil {
		a.setToast(err.Error(), true)
		return nil
	}
	if !cfg.NodeDeployed || !core.Installed() {
		a.setToast(lang.T("domain_switched")+": "+domain, false)
		return nil
	}
	return a.startTask(lang.T("domain_switch"), func(ctx context.Context, log func(string)) error {
		if err := writeConfig(cfg); err != nil {
			return err
		}
		if err := service.Do(ctx, "restart"); err != nil {
			return err
		}
		log(lang.T("domain_switched") + ": " + domain)
		log(lang.T("domain_applied"))
		return nil
	})
}

func confirmRemoveCert(a *App, domain string) tea.Cmd {
	lang := a.lang
	cfg := state.Load()
	clearActive := cfg.CertDomain == domain
	a.openForm(lang.T("domain_remove"), domainRemovePrompt(lang, domain), "", "", func(a *App, value string) (tea.Cmd, error) {
		switch strings.ToLower(strings.TrimSpace(value)) {
		case "y", "yes":
			return a.startTask(lang.T("domain_remove"), removeCertTask(lang, domain, clearActive)), nil
		default:
			return nil, errors.New(lang.T("cancelled"))
		}
	})
	return nil
}

func removeCertTask(lang i18n.Lang, domain string, clearActive bool) taskFunc {
	return func(ctx context.Context, log func(string)) error {
		if err := cert.Remove(ctx, domain); err != nil {
			log("acme remove: " + err.Error())
		}
		if clearActive {
			cfg := state.Load()
			cfg.CertDomain = ""
			if cfg.Domain == domain {
				cfg.Domain = ""
			}
			if err := cfg.Save(); err != nil {
				return err
			}
		}
		log(lang.T("domain_removed") + ": " + domain)
		return nil
	}
}

// certMenu builds a menu whose rows are the certificates currently on disk.
func certMenu(id string, domains []string, pick func(*App, string) tea.Cmd) *menu {
	nodes := make([]*node, 0, len(domains))
	for _, domain := range domains {
		domain := domain
		nodes = append(nodes, &node{
			id: id + "-" + domain,
			label: func(l i18n.Lang) string {
				if state.Load().CertDomain == domain {
					return domain + "  (" + l.T("domain_active") + ")"
				}
				return domain
			},
			desc: tk("domain_select"),
			action: func(a *App) tea.Cmd {
				return pick(a, domain)
			},
		})
	}
	return &menu{id: id, title: tk("domain_title"), nodes: nodes}
}

func domainRemovePrompt(lang i18n.Lang, domain string) string {
	return strings.Replace(lang.T("domain_remove_confirm"), "%s", domain, 1) + " (y/N)"
}
