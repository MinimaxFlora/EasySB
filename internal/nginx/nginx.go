// Package nginx writes the lightweight static site that serves the generated
// sing-box subscription file, mirroring the legacy shell behaviour.
package nginx

import (
	"context"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"strings"
	"time"

	"github.com/MinimaxFlora/EasySB/internal/cert"
	"github.com/MinimaxFlora/EasySB/internal/service"
	"github.com/MinimaxFlora/EasySB/internal/state"
	"github.com/MinimaxFlora/EasySB/internal/subscribe"
	"github.com/MinimaxFlora/EasySB/internal/sysinfo"
)

// ConfName is the site fragment written into the nginx configuration directory.
const ConfName = "easysb-sub.conf"

// ConfDir returns the nginx include directory for this distribution. The
// EASYSB_NGINX_CONF_DIR override exists for tests and unusual layouts.
func ConfDir() string {
	if dir := os.Getenv("EASYSB_NGINX_CONF_DIR"); dir != "" {
		return dir
	}
	for _, dir := range []string{"/etc/nginx/conf.d", "/etc/nginx/http.d"} {
		if info, err := os.Stat(dir); err == nil && info.IsDir() {
			return dir
		}
	}
	return "/etc/nginx/conf.d"
}

// ConfPath returns the full path of the EasySB site fragment.
func ConfPath() string {
	return ConfDir() + "/" + ConfName
}

// Available reports whether the nginx binary is on PATH.
func Available() bool {
	_, err := exec.LookPath("nginx")
	return err == nil
}

// Ensure installs nginx through the detected package manager when missing.
func Ensure(ctx context.Context, log func(string)) error {
	if Available() {
		return nil
	}
	mgr := packageManager()
	if mgr == "" {
		return errors.New("no supported package manager to install nginx")
	}
	log("install nginx via " + mgr)
	cmd := exec.CommandContext(ctx, "sh", "-c", installCommand(mgr))
	cmd.Env = append(os.Environ(), "LC_ALL=C", "DEBIAN_FRONTEND=noninteractive")
	out, err := cmd.CombinedOutput()
	if err != nil {
		return errors.New("install nginx: " + lastLine(string(out)))
	}
	if !Available() {
		return errors.New("nginx still unavailable after install")
	}
	return nil
}

func packageManager() string {
	for _, name := range []string{"apt-get", "dnf", "yum", "apk", "pacman", "zypper"} {
		if _, err := exec.LookPath(name); err == nil {
			return name
		}
	}
	return ""
}

func installCommand(mgr string) string {
	switch mgr {
	case "apt-get":
		return "apt-get update -qq && apt-get install -y -qq nginx"
	case "dnf":
		return "dnf install -y -q nginx"
	case "yum":
		return "yum install -y -q nginx"
	case "apk":
		return "apk add --no-cache nginx"
	case "pacman":
		return "pacman -Sy --noconfirm --needed nginx"
	case "zypper":
		return "zypper -n install nginx"
	}
	return ""
}

// WriteSite renders and installs the subscription site, then validates and
// restarts nginx. It requires a deployed node and a resolvable host.
func WriteSite(cfg state.Config) error {
	body, err := renderSite(cfg)
	if err != nil {
		return err
	}
	if err := os.MkdirAll(ConfDir(), 0o755); err != nil {
		return err
	}
	if err := os.WriteFile(ConfPath(), []byte(body), 0o644); err != nil {
		return err
	}
	if err := Test(); err != nil {
		return err
	}
	return Do("restart")
}

// renderSite builds the nginx server block for the current state. It serves the
// legacy /subscribe path plus one UUID-tokenised endpoint per client format.
func renderSite(cfg state.Config) (string, error) {
	host := cfg.Host()
	if host == "" {
		return "", errors.New("no server address")
	}
	port := cfg.SubPort
	if port == "" {
		port = state.DefaultSubPort
	}
	path := cfg.SubPath
	if path == "" {
		path = state.DefaultSubPath
	}
	if !strings.HasPrefix(path, "/") {
		path = "/" + path
	}
	subFile := sysinfo.SubscribeDir + "/" + subscribe.ClientFile(subscribe.ClientSingBox)

	locations := clientLocations(cfg)
	locations += fmt.Sprintf(`    location %s {
        alias %s;
        default_type application/json;
        add_header Cache-Control no-store;
    }

`, path, subFile)

	if cfg.Domain != "" {
		pair, err := cert.ResolveActive(cfg.Domain)
		if err != nil {
			return "", err
		}
		return fmt.Sprintf(`server {
    listen %s ssl;
    listen [::]:%s ssl;
    server_name %s;

    ssl_certificate     %s;
    ssl_certificate_key %s;
    ssl_protocols       TLSv1.2 TLSv1.3;

%s    location / {
        return 404;
    }
}
`, port, port, cfg.Domain, pair.Fullchain, pair.Key, locations), nil
	}
	return fmt.Sprintf(`server {
    listen %s;
    listen [::]:%s;
    server_name _;

%s    location / {
        return 404;
    }
}
`, port, port, locations), nil
}

// clientLocations renders the exact-match location block for every client
// subscription. It is empty until a UUID exists, since the UUID is the token in
// the URL.
func clientLocations(cfg state.Config) string {
	if cfg.UUID == "" {
		return ""
	}
	var b strings.Builder
	for _, client := range subscribe.Clients {
		fmt.Fprintf(&b, `    location = %s {
        alias %s/%s;
        default_type %s;
        add_header Cache-Control no-store;
    }

`, subscribe.ClientPath(cfg, client), sysinfo.SubscribeDir, subscribe.ClientFile(client), contentType(client))
	}
	return b.String()
}

func contentType(client subscribe.Client) string {
	switch client {
	case subscribe.ClientMihomo:
		// The value is quoted because nginx does not split on ";" here: an
		// unquoted `text/yaml; charset=utf-8` becomes the bogus directive
		// `charset=utf-8`.
		return `"text/yaml; charset=utf-8"`
	case subscribe.ClientV2Ray:
		return `"text/plain; charset=utf-8"`
	default:
		return "application/json"
	}
}

// RemoveSite deletes the site fragment and reloads nginx when possible.
func RemoveSite() error {
	if err := os.Remove(ConfPath()); err != nil && !os.IsNotExist(err) {
		return err
	}
	if Available() {
		_ = Do("restart")
	}
	return nil
}

// Test runs `nginx -t` to validate the configuration.
func Test() error {
	if !Available() {
		return errors.New("nginx is not installed")
	}
	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
	defer cancel()
	cmd := exec.CommandContext(ctx, "nginx", "-t")
	cmd.Env = append(os.Environ(), "LC_ALL=C")
	out, err := cmd.CombinedOutput()
	if err != nil {
		return errors.New("nginx -t: " + errorLine(string(out)))
	}
	return nil
}

// errorLine returns the most useful line from `nginx -t` output. The final line
// only says the test failed, so prefer the first [emerg]/[error] line.
func errorLine(s string) string {
	for _, line := range strings.Split(s, "\n") {
		if strings.Contains(line, "[emerg]") || strings.Contains(line, "[error]") {
			return strings.TrimSpace(line)
		}
	}
	return lastLine(s)
}

// Do performs a lifecycle action on the nginx service.
func Do(action string) error {
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	name, args := "systemctl", []string{action, "nginx"}
	if service.Detect() == service.OpenRC {
		name, args = "rc-service", []string{"nginx", action}
	}
	cmd := exec.CommandContext(ctx, name, args...)
	cmd.Env = append(os.Environ(), "LC_ALL=C")
	out, err := cmd.CombinedOutput()
	if err != nil {
		return errors.New("nginx " + action + ": " + lastLine(string(out)))
	}
	return nil
}

func lastLine(s string) string {
	lines := strings.Split(strings.TrimSpace(s), "\n")
	if len(lines) == 0 {
		return s
	}
	return lines[len(lines)-1]
}
