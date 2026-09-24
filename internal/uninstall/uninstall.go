// Package uninstall removes the EasySB deployment, keeping acme.sh certificates
// like the legacy shell implementation.
package uninstall

import (
	"context"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"strings"
	"time"

	"github.com/MinimaxFlora/EasySB/internal/cert"
	"github.com/MinimaxFlora/EasySB/internal/firewall"
	"github.com/MinimaxFlora/EasySB/internal/service"
	"github.com/MinimaxFlora/EasySB/internal/state"
	"github.com/MinimaxFlora/EasySB/internal/subd"
	"github.com/MinimaxFlora/EasySB/internal/sysinfo"
)

// BackupDir is where the pre-uninstall archive is written.
const BackupDir = "/root"

// shortcuts lists the launcher paths removed on uninstall. They are the same paths the
// installer uses, so the list lives with the rest of the install paths.
var shortcuts = sysinfo.PanelPaths

// Backup archives /etc/sing-box into /root and returns the archive path.
func Backup(log func(string)) (string, error) {
	if _, err := os.Stat(sysinfo.WorkDir); err != nil {
		return "", nil
	}
	stamp := time.Now().Format("20060102-150405")
	archive := fmt.Sprintf("%s/easysb-backup-%s.tar.gz", BackupDir, stamp)
	if _, err := exec.LookPath("tar"); err != nil {
		return "", errors.New("tar not available")
	}
	ctx, cancel := context.WithTimeout(context.Background(), 60*time.Second)
	defer cancel()
	cmd := exec.CommandContext(ctx, "tar", "-czf", archive, "-C", "/etc", "sing-box")
	cmd.Env = append(os.Environ(), "LC_ALL=C")
	if out, err := cmd.CombinedOutput(); err != nil {
		return "", errors.New("backup: " + strings.TrimSpace(string(out)))
	}
	log("backup: " + archive)
	return archive, nil
}

// Run performs the full uninstall sequence.
func Run(ctx context.Context, log func(string)) error {
	cfg := state.Load()

	if _, err := Backup(log); err != nil {
		log("backup failed: " + err.Error())
	}

	log("$ service stop/disable " + sysinfo.ServiceName)
	if err := service.Do(ctx, "stop"); err != nil {
		log("stop: " + err.Error())
	}
	if err := service.Do(ctx, "disable"); err != nil {
		log("disable: " + err.Error())
	}

	// The subscription service serves the accounts to the outside world, so it
	// goes before the files it reads do.
	log("$ service stop/disable " + sysinfo.SubServiceName)
	if err := subd.Do(ctx, "stop"); err != nil {
		log("stop subscription: " + err.Error())
	}
	if err := subd.Do(ctx, "disable"); err != nil {
		log("disable subscription: " + err.Error())
	}

	if err := firewall.Remove(ctx, cfg); err != nil {
		log("firewall remove: " + err.Error())
	}
	if err := firewall.UnitAction(ctx, "disable"); err != nil {
		log("firewall disable: " + err.Error())
	}
	if err := firewall.RemoveUnit(); err != nil {
		log("firewall unit: " + err.Error())
	}

	if err := service.RemoveUnit(); err != nil {
		log("service unit: " + err.Error())
	}
	if err := subd.RemoveUnit(); err != nil {
		log("subscription unit: " + err.Error())
	}

	if err := os.RemoveAll(sysinfo.WorkDir); err != nil {
		log("remove " + sysinfo.WorkDir + ": " + err.Error())
	}
	for _, path := range shortcuts {
		if err := os.Remove(path); err != nil && !os.IsNotExist(err) {
			log("remove " + path + ": " + err.Error())
		}
	}

	log("done")
	if cert.ACMEInstalled() {
		log("acme certificates kept in " + cert.ACMEDir())
	}
	return nil
}
