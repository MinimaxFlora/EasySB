// Package service installs and controls the sing-box system service, supporting
// both systemd and OpenRC like the legacy shell implementation.
package service

import (
	"context"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"strings"
	"time"

	"github.com/MinimaxFlora/EasySB/internal/sysinfo"
)

// ProjectHome is referenced in the generated unit for documentation.
const ProjectHome = "https://github.com/MinimaxFlora/EasySB"

// Manager identifies the init system in use.
type Manager string

const (
	Systemd Manager = "systemd"
	OpenRC  Manager = "openrc"
	Unknown Manager = "unknown"
)

// Detect reports which init system is available.
func Detect() Manager {
	if _, err := os.Stat("/run/systemd/system"); err == nil {
		return Systemd
	}
	if _, err := exec.LookPath("systemctl"); err == nil {
		return Systemd
	}
	if _, err := exec.LookPath("rc-service"); err == nil {
		return OpenRC
	}
	return Unknown
}

// UnitPath returns where the service unit should live.
func UnitPath() string {
	if Detect() == OpenRC {
		return sysinfo.OpenRCUnit
	}
	return sysinfo.SystemdUnit
}

// WriteUnit writes the service definition for the current manager. The node runs inside
// the panel binary now (`easysb core run -c …`), so the unit names the panel rather than
// a separate sing-box executable: there is no core binary to keep in sync with it.
func WriteUnit() error {
	exe, err := nodeExecutable()
	if err != nil {
		return err
	}
	unit, mode := unitContent(Detect(), exe)
	if err := os.WriteFile(UnitPath(), []byte(unit), mode); err != nil {
		return err
	}
	if Detect() == OpenRC {
		return nil
	}
	return DaemonReload()
}

// unitContent renders the unit the given manager gets, so the text (and what it points at)
// is testable without touching /etc.
func unitContent(m Manager, exe string) (string, os.FileMode) {
	if m == OpenRC {
		return fmt.Sprintf(`#!/sbin/openrc-run
name="sing-box"
description="sing-box service (EasySB)"
command="%s"
command_args="core run -c %s"
command_background=true
pidfile="/run/${RC_SVCNAME}.pid"
output_log="%s"
error_log="%s"
`, exe, sysinfo.ConfigJSON, sysinfo.LogFile, sysinfo.LogFile), 0o755
	}
	return fmt.Sprintf(`[Unit]
Description=sing-box service (EasySB)
Documentation=%s
After=network.target nss-lookup.target

[Service]
Type=simple
ExecStart=%s core run -c %s
Restart=on-failure
RestartSec=3
LimitNOFILE=infinity

[Install]
WantedBy=multi-user.target
`, ProjectHome, exe, sysinfo.ConfigJSON), 0o644
}

// nodeExecutable is the panel binary the node unit should run: the installed one when
// there is one, otherwise this process.
func nodeExecutable() (string, error) {
	self, err := os.Executable()
	if err != nil {
		self = ""
	}
	picked := sysinfo.PreferredExecutable(self, sysinfo.PanelPaths)
	if picked == "" {
		return "", errors.New("cannot determine the panel executable")
	}
	return picked, nil
}

// RemoveUnit deletes the service definition for the current manager.
func RemoveUnit() error {
	if err := os.Remove(UnitPath()); err != nil && !os.IsNotExist(err) {
		return err
	}
	if Detect() == Systemd {
		return DaemonReload()
	}
	return nil
}

// DaemonReload refreshes the systemd unit cache.
func DaemonReload() error {
	if Detect() != Systemd {
		return nil
	}
	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()
	cmd := exec.CommandContext(ctx, "systemctl", "daemon-reload")
	cmd.Env = append(os.Environ(), "LC_ALL=C")
	out, err := cmd.CombinedOutput()
	if err != nil {
		return wrap("daemon-reload", out, err)
	}
	return nil
}

// Command is the command line Do runs for an action, so a log line naming the
// command cannot disagree with what was run — on OpenRC the command is
// rc-service, not systemctl.
func Command(action string) string {
	name, args := command(action)
	return name + " " + strings.Join(args, " ")
}

// command maps an action onto the tool of the init system in use.
func command(action string) (string, []string) {
	if Detect() == OpenRC {
		name := "rc-service"
		args := []string{sysinfo.ServiceName, action}
		if action == "enable" {
			name, args = "rc-update", []string{"add", sysinfo.ServiceName, "default"}
		} else if action == "disable" {
			name, args = "rc-update", []string{"del", sysinfo.ServiceName, "default"}
		}
		return name, args
	}
	return "systemctl", []string{action, sysinfo.ServiceName}
}

// Do performs a lifecycle action: start, stop, restart, enable or disable.
func Do(ctx context.Context, action string) error {
	name, args := command(action)

	cmd := exec.CommandContext(ctx, name, args...)
	cmd.Env = append(os.Environ(), "LC_ALL=C")
	out, err := cmd.CombinedOutput()
	if err != nil {
		return wrap(action, out, err)
	}
	return nil
}

// Active reports whether the sing-box service is currently running.
func Active(ctx context.Context) bool {
	if Detect() == OpenRC {
		cmd := exec.CommandContext(ctx, "rc-service", sysinfo.ServiceName, "status")
		return cmd.Run() == nil
	}
	cmd := exec.CommandContext(ctx, "systemctl", "is-active", "--quiet", sysinfo.ServiceName)
	return cmd.Run() == nil
}

func wrap(action string, out []byte, err error) error {
	msg := strings.TrimSpace(string(out))
	if msg == "" {
		msg = err.Error()
	}
	return errors.New(action + " " + sysinfo.ServiceName + ": " + msg)
}
