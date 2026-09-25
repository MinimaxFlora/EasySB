// Package kernel owns the single install path for the sing-box core: what one
// channel/source combination means, whether that combination is already
// installed, and what has to follow an install — recording where the core came
// from, and regenerating the deployed config when the new core can express
// something the old one could not.
//
// The panel and the headless `--install-core` mode (which `install.sh` runs, so a
// one-click install comes with a core) both call this package. One path means a
// core installed by the installer and one installed from the menu cannot drift
// apart.
package kernel

import (
	"context"
	"errors"
	"os"
	"strings"

	"github.com/MinimaxFlora/EasySB/internal/core"
	"github.com/MinimaxFlora/EasySB/internal/i18n"
	"github.com/MinimaxFlora/EasySB/internal/service"
	"github.com/MinimaxFlora/EasySB/internal/state"
	"github.com/MinimaxFlora/EasySB/internal/sysinfo"
)

// Request is one install request.
type Request struct {
	// Channel is "stable" or "alpha", the same strings core.InstalledChannel
	// reports.
	Channel string
	// Source is core.SourceBuild (this repository's build, with the counters) or
	// core.SourceUpstream (the official release).
	Source string
	// DoneKey is the i18n key of the closing line: "kernel_installed" for an
	// install, "kernel_updated" for a version refresh.
	DoneKey string
	// Force reinstalls a combination that is already there, which is what a
	// version refresh asks for.
	Force bool
	// OnlyIfMissing skips the install entirely when any core is installed, whatever
	// its source. This is what the one-click installer asks for: it brings a core so
	// the panel is usable, but replacing the core of a running node is a decision for
	// the operator, not a side effect of upgrading the panel.
	OnlyIfMissing bool
}

// Normalize fills in what a caller left open. The default is what a fresh
// install gets: the author source's stable channel, the build per-account
// accounting needs.
func (r Request) Normalize() Request {
	if r.Channel != "alpha" {
		r.Channel = "stable"
	}
	if r.Source != core.SourceUpstream {
		r.Source = core.SourceBuild
	}
	if r.DoneKey == "" {
		r.DoneKey = "kernel_installed"
	}
	return r
}

// Options is what an install needs from its caller: where its lines go, and the
// deploy path to use when the newly installed core no longer serves the config
// on disk. A nil Redeploy is allowed — the headless installer has no deploy path,
// the panel does — and then the mismatch is reported instead of repaired.
type Options struct {
	Lang     i18n.Lang
	Log      func(string)
	Progress core.Progress
	Redeploy func(ctx context.Context) error
}

// Install fetches, installs and applies one combination: it stops the running
// core, downloads and extracts the build, records where it came from, and leaves
// the node in a state that matches the core that is now installed. It reports the
// installed version, which is empty when the request had nothing to do.
func Install(ctx context.Context, opts Options, req Request) (string, error) {
	req = req.Normalize()
	log := logger(opts.Log)

	cfg := state.Load()
	installed := core.Installed()
	if installed && req.OnlyIfMissing {
		log(opts.Lang.T("kernel_present_skip"))
		return "", nil
	}
	// Comparing the source too is what makes a switch reversible: after taking
	// the official core, asking for the author's build is a real change.
	if !req.Force && Same(installed, core.InstalledChannel(cfg.CoreChannel), SourceFrom(cfg.CoreSource, core.SupportsV2RayStats(ctx)), req.Channel, req.Source) {
		log(opts.Lang.T("kernel_already") + ": " + opts.Lang.T(CombinationKey(req.Channel, req.Source)))
		return "", nil
	}

	rels, err := core.FetchPreferred(ctx)
	if req.Source == core.SourceUpstream {
		rels, err = core.FetchReleases(ctx)
	}
	if err != nil {
		log(opts.Lang.T("ver_offline"))
	}
	rel := rels.Stable
	if req.Channel == "alpha" {
		rel = rels.Alpha
	}
	if rel.Version == "" {
		return "", errors.New(opts.Lang.T("kernel_no_version"))
	}
	// Where the core comes from decides whether the node can account usage, so it
	// is said out loud on every install rather than left in the code.
	if rel.Source == core.SourceBuild {
		log(opts.Lang.T("kernel_source_build"))
	} else {
		log(opts.Lang.T("kernel_source_upstream"))
		log(opts.Lang.T("kernel_source_official_warn"))
	}

	if installed {
		log("$ " + service.Command("stop"))
		_ = service.Do(ctx, "stop")
	}
	log(opts.Lang.T("kernel_downloading") + ": " + opts.Lang.T(CombinationKey(req.Channel, rel.Source)) + " " + rel.Version)
	version, err := core.Install(ctx, rel, log, opts.Progress)
	if err != nil {
		return "", err
	}

	// Where the core came from is recorded, because the panel shows it and because
	// the source is what decides whether usage can be counted.
	cfg.CoreSource = rel.Source
	cfg.StatsAPI = state.StatsAPINone
	if core.SupportsV2RayStats(ctx) {
		cfg.StatsAPI = ""
	}
	cfg.CoreChannel = req.Channel
	if err := cfg.Save(); err != nil {
		return version, err
	}

	Reconcile(ctx, opts)
	log(opts.Lang.T(req.DoneKey) + ": " + opts.Lang.T(CombinationKey(req.Channel, rel.Source)) + " " + version)
	return version, nil
}

// Reconcile leaves the node in a state that matches the core that is now
// installed. A core that is not running anything needs nothing: without a
// deployed config the node is deployed later, from the panel. When a config is
// there, it either still matches — and the core is started again — or the core
// changed what it can express, and the config is regenerated through the deploy
// path, because a config naming an API the binary was not built with is rejected
// whole and the node would never come up.
func Reconcile(ctx context.Context, opts Options) {
	log := logger(opts.Log)
	if !HasServerConfig() {
		return
	}
	if ConfigMatchesCore(ctx, core.SupportsV2RayStats(ctx)) {
		log("$ " + service.Command("start"))
		_ = service.Do(ctx, "start")
		return
	}
	log(opts.Lang.T("kernel_redeploy_needed"))
	if opts.Redeploy == nil {
		// No deploy path in this process: the operator is told what to do instead
		// of being left with a node that does not start.
		log(opts.Lang.T("kernel_redeploy_pending"))
		return
	}
	if err := opts.Redeploy(ctx); err != nil {
		log(opts.Lang.T("kernel_redeploy_failed") + ": " + err.Error())
	}
}

// SourceFrom reports which source an installed core came from: the recorded one
// when the panel performed the install, and otherwise what the binary's own build
// tags say (the `with_v2ray_api` tag is the only way to tell the two apart from
// the outside). One function answers this for the 看板, the version line and the
// install guard, so what the operator reads and what the panel decides cannot
// drift apart.
func SourceFrom(recorded string, statsCapable bool) string {
	if recorded != "" {
		if recorded == core.SourceBuild {
			return core.SourceBuild
		}
		return core.SourceUpstream
	}
	if statsCapable {
		return core.SourceBuild
	}
	return core.SourceUpstream
}

// Same reports whether the wanted combination of channel and source is the one
// already installed, which is the only case an install request has nothing to do.
func Same(installed bool, installedChannel, installedSource, wantChannel, wantSource string) bool {
	return installed && installedChannel == wantChannel && installedSource == wantSource
}

// CombinationKey names one of the four channel/source combinations in the
// interface.
func CombinationKey(channel, source string) string {
	if source == core.SourceBuild {
		if channel == "alpha" {
			return "kernel_alpha_author"
		}
		return "kernel_stable_author"
	}
	if channel == "alpha" {
		return "kernel_alpha_official"
	}
	return "kernel_stable_official"
}

// HasServerConfig reports whether a rendered node config is on disk.
func HasServerConfig() bool {
	info, err := os.Stat(sysinfo.ConfigJSON)
	return err == nil && info.Size() > 0
}

// ConfigMatchesCore reports whether the deployed config was rendered for the
// counters the installed core offers. Both directions of a mismatch matter: a
// config naming an API the binary was not built with is rejected whole and the
// node never starts, while a config that omits the API the binary does carry
// would count nothing at all.
func ConfigMatchesCore(ctx context.Context, capable bool) bool {
	body, err := os.ReadFile(sysinfo.ConfigJSON)
	if err != nil {
		return false
	}
	if strings.Contains(string(body), "v2ray_api") != capable {
		return false
	}
	return core.ConfigCheck(ctx, sysinfo.ConfigJSON)
}

// logger keeps every caller from nil-checking its own log sink.
func logger(log func(string)) func(string) {
	if log == nil {
		return func(string) {}
	}
	return log
}
