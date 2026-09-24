package subd

import (
	"context"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"

	"github.com/MinimaxFlora/EasySB/internal/service"
	"github.com/MinimaxFlora/EasySB/internal/sysinfo"
)

// UnitPath returns where the subscription service unit should live.
func UnitPath() string {
	if service.Detect() == service.OpenRC {
		return sysinfo.SubOpenRCUnit
	}
	return sysinfo.SubSystemdUnit
}

// WriteUnit installs the unit that keeps the endpoint running. It runs this same
// binary with --serve, so the endpoint needs no separate program.
func WriteUnit() error {
	exe, err := serviceExecutable()
	if err != nil {
		return err
	}
	return writeUnit(UnitPath(), exe, service.Detect())
}

// serviceExecutable picks the path the subscription unit should run. The installed
// panel wins over wherever this process happens to live: running a scratch copy once
// used to rewrite the unit to that copy's path, and removing the copy left the endpoint
// unable to start. A tree that was never installed still points at itself.
func serviceExecutable() (string, error) {
	self, err := os.Executable()
	if err != nil {
		self = ""
	}
	picked := pickExecutable(self, sysinfo.PanelPaths)
	if picked == "" {
		return "", errors.New("cannot determine the panel executable")
	}
	return picked, nil
}

// pickExecutable returns the first candidate that exists and is executable, preferring
// the one this process is running from; self is the fallback when none is installed.
func pickExecutable(self string, candidates []string) string {
	installed := ""
	selfResolved := ""
	if self != "" {
		if resolved, err := filepath.EvalSymlinks(self); err == nil {
			selfResolved = resolved
		}
	}
	for _, candidate := range candidates {
		info, err := os.Stat(candidate)
		if err != nil || !executable(info) {
			continue
		}
		if installed == "" {
			installed = candidate
		}
		if selfResolved != "" {
			if resolved, err := filepath.EvalSymlinks(candidate); err == nil && resolved == selfResolved {
				return candidate
			}
		}
	}
	if installed != "" {
		return installed
	}
	return self
}

// executable reports whether a file may be run. Windows has no executable bit, so there
// any regular file counts; everywhere the panel installs to, the bit is what decides, so
// a half-written download is never mistaken for the installed panel.
func executable(info os.FileInfo) bool {
	if info.IsDir() {
		return false
	}
	if runtime.GOOS == "windows" {
		return true
	}
	return info.Mode()&0o111 != 0
}

func writeUnit(path, exe string, manager service.Manager) error {
	if manager == service.OpenRC {
		unit := fmt.Sprintf(`#!/sbin/openrc-run
name="%s"
description="EasySB subscription service"
command="%s"
command_args="--serve"
command_background=true
pidfile="/run/${RC_SVCNAME}.pid"
output_log="%s"
error_log="%s"
`, sysinfo.SubServiceName, exe, sysinfo.SubLogFile, sysinfo.SubLogFile)
		return os.WriteFile(path, []byte(unit), 0o755)
	}
	unit := fmt.Sprintf(`[Unit]
Description=EasySB subscription service
Documentation=%s
After=network.target nss-lookup.target
Wants=sing-box.service

[Service]
Type=simple
ExecStart=%s --serve
Restart=always
RestartSec=5
LimitNOFILE=infinity

[Install]
WantedBy=multi-user.target
`, service.ProjectHome, exe)
	if err := os.WriteFile(path, []byte(unit), 0o644); err != nil {
		return err
	}
	return service.DaemonReload()
}

// RemoveUnit deletes the unit and forgets the service.
func RemoveUnit() error {
	if err := os.Remove(UnitPath()); err != nil && !os.IsNotExist(err) {
		return err
	}
	if service.Detect() == service.Systemd {
		return service.DaemonReload()
	}
	return nil
}

// Do starts, stops, restarts, enables or disables the subscription service.
func Do(ctx context.Context, action string) error {
	if service.Detect() == service.OpenRC {
		name, args := "rc-service", []string{sysinfo.SubServiceName, action}
		switch action {
		case "enable":
			name, args = "rc-update", []string{"add", sysinfo.SubServiceName, "default"}
		case "disable":
			name, args = "rc-update", []string{"del", sysinfo.SubServiceName, "default"}
		}
		out, err := exec.CommandContext(ctx, name, args...).CombinedOutput()
		if err != nil {
			return wrap(action, out, err)
		}
		return nil
	}
	if _, err := exec.LookPath("systemctl"); err != nil {
		return errors.New("systemctl not available: " + err.Error())
	}
	out, err := exec.CommandContext(ctx, "systemctl", action, sysinfo.SubServiceName).CombinedOutput()
	if err != nil {
		return wrap(action, out, err)
	}
	return nil
}

// Active reports whether the subscription service is running.
func Active(ctx context.Context) bool {
	if service.Detect() == service.OpenRC {
		return exec.CommandContext(ctx, "rc-service", sysinfo.SubServiceName, "status").Run() == nil
	}
	return exec.CommandContext(ctx, "systemctl", "is-active", "--quiet", sysinfo.SubServiceName).Run() == nil
}

func wrap(action string, out []byte, err error) error {
	msg := strings.TrimSpace(string(out))
	if msg == "" {
		msg = err.Error()
	}
	return errors.New(action + " " + sysinfo.SubServiceName + ": " + msg)
}
