// Package deploy turns the node state and the account list into a running
// deployment: it renders config.json, validates it with the core, restarts the
// service and records which accounts are live. The panel and the subscription
// service both go through it, so a change made in either one produces the same
// configuration.
package deploy

import (
	"context"
	"errors"
	"os"
	"time"

	"github.com/MinimaxFlora/EasySB/internal/cert"
	"github.com/MinimaxFlora/EasySB/internal/config"
	"github.com/MinimaxFlora/EasySB/internal/core"
	"github.com/MinimaxFlora/EasySB/internal/service"
	"github.com/MinimaxFlora/EasySB/internal/state"
	"github.com/MinimaxFlora/EasySB/internal/sysinfo"
	"github.com/MinimaxFlora/EasySB/internal/user"
)

// ErrNoCore is returned when the core is missing, which no configuration can
// make up for.
var ErrNoCore = errors.New("sing-box is not installed")

// ErrRejected is returned when the core refuses the generated configuration.
var ErrRejected = errors.New("the core rejected the generated configuration")

// ServerConfig renders the core configuration for a set of accounts. The
// listener set is exactly the given accounts, so a caller that leaves an account
// out also removes its credentials from the core.
func ServerConfig(cfg state.Config, accounts []user.User) ([]byte, error) {
	pair, err := cert.ResolveActive(cfg.Domain)
	if err != nil {
		return nil, err
	}
	params := config.ParamsFromState(cfg)
	params.CertFullchain = pair.Fullchain
	params.CertKey = pair.Key
	params.Members = config.MembersFrom(accounts)
	return config.Build(params)
}

// WriteServerConfig renders the configuration and writes it to
// /etc/sing-box/config.json.
func WriteServerConfig(cfg state.Config, accounts []user.User) ([]byte, error) {
	data, err := ServerConfig(cfg, accounts)
	if err != nil {
		return nil, err
	}
	if err := os.MkdirAll(sysinfo.WorkDir, 0o755); err != nil {
		return nil, err
	}
	if err := os.WriteFile(sysinfo.ConfigJSON, data, 0o644); err != nil {
		return nil, err
	}
	return data, nil
}

// Apply writes the configuration for the given accounts, validates it and
// restarts the core. A node that was never deployed is left alone: there is no
// certificate and no service to restart yet, and pre-created accounts must not
// fail the caller.
func Apply(ctx context.Context, cfg state.Config, accounts []user.User) error {
	if !cfg.NodeDeployed {
		return nil
	}
	if !core.Installed() {
		return ErrNoCore
	}
	if _, err := WriteServerConfig(cfg, accounts); err != nil {
		return err
	}
	if !core.ConfigCheck(ctx, sysinfo.ConfigJSON) {
		return ErrRejected
	}
	return service.Do(ctx, "restart")
}

// ApplyStore applies the accounts that may be live right now and records them,
// which is the single write path for a change made in the panel.
func ApplyStore(ctx context.Context, cfg state.Config, store *user.Store) error {
	now := time.Now()
	if err := Apply(ctx, cfg, store.Routable(now)); err != nil {
		return err
	}
	store.MarkApplied(now)
	return store.Save()
}
