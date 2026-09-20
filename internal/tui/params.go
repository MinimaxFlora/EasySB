package tui

import (
	"context"
	"errors"
	"fmt"
	"strconv"
	"strings"

	tea "charm.land/bubbletea/v2"

	"github.com/MinimaxFlora/EasySB/internal/core"
	"github.com/MinimaxFlora/EasySB/internal/secret"
	"github.com/MinimaxFlora/EasySB/internal/state"
)

// editUUID prompts for the node UUID, auto-generating one on empty input.
func editUUID() actionFunc {
	return func(a *App) tea.Cmd {
		lang := a.lang
		cfg := state.Load()
		a.openForm(lang.T("param_uuid"), lang.T("param_uuid_prompt"), cfg.UUID, lang.T("param_uuid_gen"), func(a *App, value string) error {
			value = strings.TrimSpace(value)
			if value == "" {
				value = core.GenerateUUID(context.Background())
			}
			if value == "" {
				return errors.New(lang.T("invalid"))
			}
			cfg.UUID = value
			if err := cfg.Save(); err != nil {
				return err
			}
			a.setToast(lang.T("node_params_saved"), false)
			return nil
		})
		return nil
	}
}

// editPassword prompts for the shared protocol password.
func editPassword() actionFunc {
	return func(a *App) tea.Cmd {
		lang := a.lang
		cfg := state.Load()
		a.openForm(lang.T("param_password"), lang.T("param_pw_prompt"), cfg.Password, lang.T("param_pw_gen"), func(a *App, value string) error {
			value = strings.TrimSpace(value)
			if value == "" {
				value = secret.Password()
			}
			if value == "" {
				return errors.New(lang.T("invalid"))
			}
			cfg.Password = value
			if err := cfg.Save(); err != nil {
				return err
			}
			a.setToast(lang.T("node_params_saved"), false)
			return nil
		})
		return nil
	}
}

// editHop prompts for the Hysteria2 port-hopping range.
func editHop() actionFunc {
	return func(a *App) tea.Cmd {
		lang := a.lang
		cfg := state.Load()
		prompt := fmt.Sprintf(lang.T("param_hop_prompt"), state.DefaultHopRange)
		a.openForm(lang.T("param_hop"), prompt, cfg.HopRange, "", func(a *App, value string) error {
			value = strings.TrimSpace(value)
			if value == "" {
				value = state.DefaultHopRange
			}
			if !validHopRange(value) {
				return errors.New(lang.T("param_invalid_range"))
			}
			cfg.HopRange = value
			if err := cfg.Save(); err != nil {
				return err
			}
			a.setToast(lang.T("node_params_saved"), false)
			return nil
		})
		return nil
	}
}

// validHopRange accepts "start:end" with start < end and both in 1..65535.
func validHopRange(s string) bool {
	start, end, ok := strings.Cut(s, ":")
	if !ok {
		return false
	}
	lo, err1 := strconv.Atoi(start)
	hi, err2 := strconv.Atoi(end)
	if err1 != nil || err2 != nil {
		return false
	}
	return lo >= 1 && lo < hi && hi <= 65535
}

// editPort prompts for a single protocol port, rejecting conflicts.
func editPort(proto string) actionFunc {
	return func(a *App) tea.Cmd {
		lang := a.lang
		cfg := state.Load()
		prompt := fmt.Sprintf(lang.T("param_port_prompt"), cfg.Ports[proto])
		a.openForm(state.Labels[proto], prompt, cfg.Ports[proto], "", func(a *App, value string) error {
			value = strings.TrimSpace(value)
			if value == "" {
				value = cfg.Ports[proto]
			}
			n, err := strconv.Atoi(value)
			if err != nil || n < 1 || n > 65535 {
				return errors.New(lang.T("port_invalid"))
			}
			for _, k := range state.Keys {
				if k != proto && cfg.Ports[k] == value {
					return errors.New(lang.T("port_conflict"))
				}
			}
			cfg.Ports[proto] = value
			if err := cfg.Save(); err != nil {
				return err
			}
			a.setToast(lang.T("node_params_saved"), false)
			return nil
		})
		return nil
	}
}

// setSNI applies a preset handshake domain immediately.
func setSNI(preset string) actionFunc {
	return func(a *App) tea.Cmd {
		lang := a.lang
		cfg := state.Load()
		cfg.RealitySNI = preset
		if err := cfg.Save(); err != nil {
			a.setToast(err.Error(), true)
			return nil
		}
		a.setToast(lang.T("param_sni")+" = "+preset, false)
		return nil
	}
}

// editSNI prompts for a custom handshake domain.
func editSNI() actionFunc {
	return func(a *App) tea.Cmd {
		lang := a.lang
		cfg := state.Load()
		current := cfg.RealitySNI
		if current == "" {
			current = state.DefaultSNI
		}
		prompt := fmt.Sprintf(lang.T("param_sni_prompt"), current)
		a.openForm(lang.T("param_sni"), prompt, current, "", func(a *App, value string) error {
			value = strings.TrimSpace(value)
			if value == "" {
				value = current
			}
			cfg.RealitySNI = value
			if err := cfg.Save(); err != nil {
				return err
			}
			a.setToast(lang.T("node_params_saved"), false)
			return nil
		})
		return nil
	}
}

// regenRealityKeys regenerates the Reality keypair with the installed core.
func regenRealityKeys() actionFunc {
	return func(a *App) tea.Cmd {
		lang := a.lang
		return a.startTask(lang.T("param_privkey"), func(ctx context.Context, log func(string)) error {
			if !core.Installed() {
				return errors.New(lang.T("param_install_core_first"))
			}
			priv, pub, err := core.RealityKeypair(ctx)
			if err != nil {
				return err
			}
			cfg := state.Load()
			cfg.RealityPriv = priv
			cfg.RealityPub = pub
			if err := cfg.Save(); err != nil {
				return err
			}
			log(lang.T("param_regen_privkey"))
			return nil
		})
	}
}

// regenShortID regenerates the Reality short id.
func regenShortID() actionFunc {
	return func(a *App) tea.Cmd {
		lang := a.lang
		cfg := state.Load()
		cfg.RealitySID = secret.ShortID()
		if err := cfg.Save(); err != nil {
			a.setToast(err.Error(), true)
			return nil
		}
		a.setToast(lang.T("param_regen_shortid"), false)
		return collectStatus(a.scriptVersion)
	}
}

// toggleProtocol flips one protocol's enabled flag.
func toggleProtocol(proto string) actionFunc {
	return func(a *App) tea.Cmd {
		cfg := state.Load()
		cfg.Enabled[proto] = !cfg.Enabled[proto]
		if err := cfg.Save(); err != nil {
			a.setToast(err.Error(), true)
			return nil
		}
		return nil
	}
}
