package apps

import (
	"archive/tar"
	"archive/zip"
	"bufio"
	"compress/gzip"
	"context"
	"crypto/md5"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"hash"
	"io"
	"net"
	"net/http"
	"os"
	"os/exec"
	"path"
	"path/filepath"
	"strings"
	"time"

	"github.com/MinimaxFlora/EasySB/internal/service"
	"github.com/MinimaxFlora/EasySB/internal/state"
)

// Progress reports download progress, in bytes.
type Progress func(done, total int64)

// Request is one install or update run.
type Request struct {
	App App
	// Version pins the release to install. Empty means the newest release.
	Version string
	// Port is the listen port the service is configured with, and Domain the
	// public domain the site is served under (used by applications that build
	// absolute URLs).
	Port   int
	Domain string
	// Force reinstalls even when the installed version already matches.
	Force bool
	Log   func(string)
	// Progress is optional; a nil Progress installs silently.
	Progress Progress
}

// Port is the port an application runs on: the operator's choice when the state
// file records one, the application's own default otherwise.
func Port(cfg state.Config, a App) int {
	if p := cfg.AppPort(a.ID); p > 0 {
		return p
	}
	return a.Port
}

// client is used for every release download. The timeout is generous because a
// dashboard binary is tens of megabytes and a slow VPS is normal; the releases
// API call uses its own short timeout.
var client = &http.Client{Timeout: 30 * time.Minute}

const apiTimeout = 25 * time.Second

// userAgent identifies this tool to GitHub, which rejects requests without one.
const userAgent = "EasySB"

// Release returns the newest release tag of an application.
func Release(ctx context.Context, a App) (string, error) {
	ctx, cancel := context.WithTimeout(ctx, apiTimeout)
	defer cancel()

	url := "https://api.github.com/repos/" + a.Repo + "/releases/latest"
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, url, nil)
	if err != nil {
		return "", err
	}
	req.Header.Set("User-Agent", userAgent)
	req.Header.Set("Accept", "application/vnd.github+json")

	resp, err := client.Do(req)
	if err != nil {
		return "", err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return "", fmt.Errorf("%s: releases API returned %s", a.Name, resp.Status)
	}
	var rel struct {
		TagName string `json:"tag_name"`
	}
	if err := json.NewDecoder(io.LimitReader(resp.Body, 1<<20)).Decode(&rel); err != nil {
		return "", err
	}
	if rel.TagName == "" {
		return "", fmt.Errorf("%s: releases API returned no tag", a.Name)
	}
	return rel.TagName, nil
}

// Installed reports whether the application's binary is in place.
func Installed(a App) bool {
	info, err := os.Stat(a.Binary)
	return err == nil && !info.IsDir()
}

// Version is the version recorded for the installed binary, empty when unknown.
func Version(a App) string {
	body, err := os.ReadFile(a.VersionPath())
	if err != nil {
		return ""
	}
	return strings.TrimSpace(string(body))
}

// Active reports whether the application's service is running.
func Active(ctx context.Context, a App) bool {
	if service.Detect() == service.OpenRC {
		return exec.CommandContext(ctx, "rc-service", a.UnitName(), "status").Run() == nil
	}
	return exec.CommandContext(ctx, "systemctl", "is-active", "--quiet", a.UnitName()).Run() == nil
}

// Status summarises an application for the panel: not-installed, stopped or
// running.
func Status(ctx context.Context, a App) string {
	switch {
	case !Installed(a):
		return "not-installed"
	case Active(ctx, a):
		return "running"
	default:
		return "stopped"
	}
}

// Control runs a lifecycle action on the application's own service.
func Control(ctx context.Context, a App, action string) error {
	name, args := "systemctl", []string{action, a.UnitName()}
	if service.Detect() == service.OpenRC {
		name, args = "rc-service", []string{a.UnitName(), action}
		if action == "enable" {
			name, args = "rc-update", []string{"add", a.UnitName(), "default"}
		} else if action == "disable" {
			name, args = "rc-update", []string{"del", a.UnitName(), "default"}
		}
	}
	ctx, cancel := context.WithTimeout(ctx, 60*time.Second)
	defer cancel()
	cmd := exec.CommandContext(ctx, name, args...)
	cmd.Env = append(os.Environ(), "LC_ALL=C")
	out, err := cmd.CombinedOutput()
	if err != nil {
		return fmt.Errorf("%s %s: %s", name, strings.Join(args, " "), firstLine(out, err))
	}
	return nil
}

// Logs returns the tail of the application's log, which is where an application
// prints the password it generated for its first login.
func Logs(ctx context.Context, a App, lines int) string {
	if lines <= 0 {
		lines = 40
	}
	if service.Detect() == service.OpenRC {
		body, err := os.ReadFile("/var/log/" + a.UnitName() + ".log")
		if err != nil {
			return ""
		}
		return tail(string(body), lines)
	}
	ctx, cancel := context.WithTimeout(ctx, 20*time.Second)
	defer cancel()
	cmd := exec.CommandContext(ctx, "journalctl", "-u", a.UnitName(), "-n", fmt.Sprint(lines), "--no-pager", "-o", "cat")
	out, err := cmd.Output()
	if err != nil && len(out) == 0 {
		return ""
	}
	return string(out)
}

// Install downloads, verifies and installs the application, then writes and starts
// its service. It returns the installed version.
func Install(ctx context.Context, req Request) (string, error) {
	a := req.App
	log := req.Log
	if log == nil {
		log = func(string) {}
	}
	if Arch() == "" {
		return "", fmt.Errorf("%s: no release for this architecture", a.Name)
	}

	version := req.Version
	if version == "" {
		fetched, err := Release(ctx, a)
		if err != nil {
			return "", err
		}
		version = fetched
	}
	if req.Port <= 0 {
		req.Port = a.Port
	}

	if err := os.MkdirAll(a.DataDir(), 0o755); err != nil {
		return "", err
	}

	asset := a.AssetName(version)
	log(fmt.Sprintf("%s: %s (%s)", a.Name, version, asset))

	archive := a.ArchivePath()
	if err := download(ctx, a.AssetURL(version), archive, req.Progress); err != nil {
		return "", err
	}
	defer os.Remove(archive)

	if err := verify(ctx, a, version, archive, log); err != nil {
		return "", err
	}

	if err := unpack(a, version, archive, log); err != nil {
		return "", err
	}

	unit, mode := a.UnitContent(req.Port, req.Domain)
	if err := os.WriteFile(a.UnitPath(), []byte(unit), mode); err != nil {
		return "", err
	}
	if err := service.DaemonReload(); err != nil {
		return "", err
	}
	if err := Control(ctx, a, "enable"); err != nil {
		log("enable: " + err.Error())
	}
	if err := Control(ctx, a, "restart"); err != nil {
		return "", err
	}
	if err := os.WriteFile(a.VersionPath(), []byte(version+"\n"), 0o644); err != nil {
		return "", err
	}

	tune(ctx, a, req.Port, log)
	log(a.Name + ": " + "installed " + version)
	return version, nil
}

// Update installs the newest release unless the installed one already is the
// newest. It reports whether anything changed.
func Update(ctx context.Context, req Request) (bool, string, error) {
	a := req.App
	if !Installed(a) {
		version, err := Install(ctx, req)
		return true, version, err
	}
	version, err := Release(ctx, a)
	if err != nil {
		return false, "", err
	}
	if !req.Force && version == Version(a) {
		return false, version, nil
	}
	req.Version = version
	installed, err := Install(ctx, req)
	return true, installed, err
}

// Uninstall stops and removes the application's service and files. It returns the
// paths it removed so the panel can show exactly what went away.
func Uninstall(ctx context.Context, a App, log func(string)) ([]string, error) {
	if log == nil {
		log = func(string) {}
	}
	var removed []string

	_ = Control(ctx, a, "stop")
	if err := Control(ctx, a, "disable"); err != nil {
		log("disable: " + err.Error())
	}
	if err := os.Remove(a.UnitPath()); err != nil && !os.IsNotExist(err) {
		return removed, err
	}
	removed = append(removed, a.UnitPath())
	if err := service.DaemonReload(); err != nil {
		log("daemon-reload: " + err.Error())
	}
	if err := os.RemoveAll(a.Dir()); err != nil {
		return removed, err
	}
	removed = append(removed, a.Dir())
	return removed, nil
}

// download streams a URL to a file, reporting progress as it goes.
func download(ctx context.Context, url, dest string, progress Progress) error {
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, url, nil)
	if err != nil {
		return err
	}
	req.Header.Set("User-Agent", userAgent)
	resp, err := client.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return fmt.Errorf("download %s: %s", path.Base(url), resp.Status)
	}

	if err := os.MkdirAll(filepath.Dir(dest), 0o755); err != nil {
		return err
	}
	f, err := os.OpenFile(dest, os.O_CREATE|os.O_TRUNC|os.O_WRONLY, 0o600)
	if err != nil {
		return err
	}
	defer f.Close()

	var reader io.Reader = resp.Body
	if progress != nil {
		reader = io.TeeReader(resp.Body, &progressWriter{total: resp.ContentLength, report: progress})
	}
	if _, err := io.Copy(f, reader); err != nil {
		return err
	}
	return f.Sync()
}

// progressWriter throttles progress reports so a fast link does not flood the UI.
type progressWriter struct {
	done   int64
	total  int64
	last   time.Time
	report Progress
}

func (p *progressWriter) Write(b []byte) (int, error) {
	p.done += int64(len(b))
	if now := time.Now(); now.Sub(p.last) > 100*time.Millisecond {
		p.last = now
		p.report(p.done, p.total)
	}
	return len(b), nil
}

// verify checks the download against the checksum the upstream project publishes.
// A project that publishes none is reported rather than silently accepted.
func verify(ctx context.Context, a App, version, archive string, log func(string)) error {
	if a.SumAsset == "" {
		log(a.Name + ": upstream publishes no checksum, relying on HTTPS")
		return nil
	}
	ctx, cancel := context.WithTimeout(ctx, apiTimeout)
	defer cancel()

	req, err := http.NewRequestWithContext(ctx, http.MethodGet, a.SumURL(version), nil)
	if err != nil {
		return err
	}
	req.Header.Set("User-Agent", userAgent)
	resp, err := client.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return fmt.Errorf("%s: checksum file %s returned %s", a.Name, a.SumAsset, resp.Status)
	}
	body, err := io.ReadAll(io.LimitReader(resp.Body, 1<<20))
	if err != nil {
		return err
	}

	want := Checksum(string(body), a.AssetName(version))
	if want == "" {
		return fmt.Errorf("%s: %s lists no checksum for %s", a.Name, a.SumAsset, a.AssetName(version))
	}
	got, err := fileSum(a.SumKind, archive)
	if err != nil {
		return err
	}
	if !strings.EqualFold(got, want) {
		return fmt.Errorf("%s: checksum mismatch: got %s want %s", a.Name, got, want)
	}
	log(fmt.Sprintf("%s: checksum ok (%s)", a.Name, a.SumKind))
	return nil
}

// fileSum hashes a file with the named checksum.
func fileSum(kind, file string) (string, error) {
	var h hash.Hash
	switch strings.ToLower(kind) {
	case "md5":
		h = md5.New()
	case "sha256", "":
		h = sha256.New()
	default:
		return "", fmt.Errorf("unsupported checksum %q", kind)
	}
	f, err := os.Open(file)
	if err != nil {
		return "", err
	}
	defer f.Close()
	if _, err := io.Copy(h, f); err != nil {
		return "", err
	}
	return hex.EncodeToString(h.Sum(nil)), nil
}

// unpack installs the binary out of the downloaded release. The binary is written
// next to its destination and renamed, so a failed unpack cannot leave a
// half-written executable in place.
func unpack(a App, version, archive string, log func(string)) error {
	tmp := a.Binary + ".new"
	if err := os.MkdirAll(filepath.Dir(a.Binary), 0o755); err != nil {
		return err
	}
	switch a.Pack {
	case PackRaw:
		if err := copyFile(archive, tmp); err != nil {
			return err
		}
	case PackTarGz:
		if err := unpackTarGz(a, archive, tmp); err != nil {
			return err
		}
	case PackZip:
		if err := unpackZip(a, archive, tmp); err != nil {
			return err
		}
	default:
		return fmt.Errorf("%s: unsupported packaging %q", a.Name, a.Pack)
	}
	if err := os.Chmod(tmp, 0o755); err != nil {
		return err
	}
	return os.Rename(tmp, a.Binary)
}

func copyFile(from, to string) error {
	in, err := os.Open(from)
	if err != nil {
		return err
	}
	defer in.Close()
	out, err := os.OpenFile(to, os.O_CREATE|os.O_TRUNC|os.O_WRONLY, 0o755)
	if err != nil {
		return err
	}
	if _, err := io.Copy(out, in); err != nil {
		out.Close()
		return err
	}
	return out.Close()
}

// wanted reports whether an archive entry is the binary to install.
func (a App) wanted(name string) bool {
	base := path.Base(name)
	if a.File != "" {
		return base == a.File
	}
	// No configured name: accept the entry whose name starts with the asset's own
	// name (dashboards are published as "dashboard-linux-amd64"), so a release
	// that ships a README next to the executable still installs the executable.
	hint := strings.TrimSuffix(a.AssetName("0"), "."+string(a.Pack))
	return strings.HasPrefix(hint, base)
}

func unpackTarGz(a App, archive, dest string) error {
	f, err := os.Open(archive)
	if err != nil {
		return err
	}
	defer f.Close()
	gz, err := gzip.NewReader(f)
	if err != nil {
		return err
	}
	defer gz.Close()

	tr := tar.NewReader(gz)
	found := 0
	for {
		hdr, err := tr.Next()
		if err == io.EOF {
			break
		}
		if err != nil {
			return err
		}
		if hdr.Typeflag != tar.TypeReg {
			continue
		}
		if !a.wanted(hdr.Name) {
			continue
		}
		if found++; found > 1 && a.File == "" {
			return fmt.Errorf("%s: archive holds several candidates", a.Name)
		}
		if err := writeAll(dest, tr); err != nil {
			return err
		}
		if a.File != "" {
			return nil
		}
	}
	if found == 0 {
		return fmt.Errorf("%s: no binary in the archive", a.Name)
	}
	return nil
}

func unpackZip(a App, archive, dest string) error {
	zr, err := zip.OpenReader(archive)
	if err != nil {
		return err
	}
	defer zr.Close()

	found := 0
	for _, entry := range zr.File {
		if entry.FileInfo().IsDir() {
			continue
		}
		if !a.wanted(entry.Name) {
			continue
		}
		if found++; found > 1 && a.File == "" {
			return fmt.Errorf("%s: archive holds several candidates", a.Name)
		}
		rc, err := entry.Open()
		if err != nil {
			return err
		}
		err = writeAll(dest, rc)
		rc.Close()
		if err != nil {
			return err
		}
		if a.File != "" {
			return nil
		}
	}
	if found == 0 {
		return fmt.Errorf("%s: no binary in the archive", a.Name)
	}
	return nil
}

func writeAll(dest string, r io.Reader) error {
	out, err := os.OpenFile(dest, os.O_CREATE|os.O_TRUNC|os.O_WRONLY, 0o755)
	if err != nil {
		return err
	}
	if _, err := io.Copy(out, r); err != nil {
		out.Close()
		return err
	}
	return out.Close()
}

// tune rewrites the listen address of an application that keeps it in a config
// file rather than on the command line, so its port stays on the loopback
// interface. The file is written by the application on its first start, so this
// waits for it and restarts the service when it changed anything.
func tune(ctx context.Context, a App, port int, log func(string)) {
	switch a.ID {
	case "openlist":
		tuneOpenList(ctx, a, port, log)
	case "nezha":
		tuneNezha(ctx, a, port, log)
	}
}

// tuneNezha rewrites the dashboard's listen port. Nezha writes its config on the
// first start, so this waits for the file and restarts the service when it changed
// anything — the same shape as the OpenList tuning below.
func tuneNezha(ctx context.Context, a App, port int, log func(string)) {
	cfgFile := a.DataDir() + "/config.yaml"
	if !waitForFile(ctx, cfgFile, 30*time.Second) {
		log(a.Name + ": config.yaml did not appear, leaving its listen port alone")
		return
	}
	body, err := os.ReadFile(cfgFile)
	if err != nil {
		log(a.Name + ": " + err.Error())
		return
	}
	lines := strings.Split(string(body), "\n")
	changed := false
	found := false
	for i, line := range lines {
		if !strings.HasPrefix(strings.TrimSpace(line), "listen_port:") {
			continue
		}
		found = true
		want := fmt.Sprintf("listen_port: %d", port)
		if strings.TrimSpace(line) == want && !strings.HasPrefix(line, " ") {
			break
		}
		if line != want {
			lines[i], changed = want, true
		}
	}
	if !found {
		// A config without the key takes the built-in port; recording the choice
		// keeps the service and the front's target in agreement.
		lines = append(lines, fmt.Sprintf("listen_port: %d", port))
		changed = true
	}
	if !changed {
		return
	}
	if err := os.WriteFile(cfgFile, []byte(strings.Join(lines, "\n")), 0o644); err != nil {
		log(a.Name + ": " + err.Error())
		return
	}
	log(fmt.Sprintf("%s: listening on %s:%d only", a.Name, LocalHost, port))
	if err := Control(ctx, a, "restart"); err != nil {
		log("restart: " + err.Error())
	}
}

// waitForFile waits for a file an application writes on its first start.
func waitForFile(ctx context.Context, file string, limit time.Duration) bool {
	deadline := time.Now().Add(limit)
	for {
		if _, err := os.Stat(file); err == nil {
			return true
		}
		if time.Now().After(deadline) {
			return false
		}
		select {
		case <-ctx.Done():
			return false
		case <-time.After(time.Second):
		}
	}
}

// tuneOpenList rewrites the listen address of an application that keeps it in a config
// file rather than on the command line, so its port stays on the loopback interface.
// The file is written by the application on its first start, so this waits for it and
// restarts the service when it changed anything.
func tuneOpenList(ctx context.Context, a App, port int, log func(string)) {
	cfgFile := a.DataDir() + "/config.json"
	if !waitForFile(ctx, cfgFile, 30*time.Second) {
		log(a.Name + ": config.json did not appear, leaving its listen address alone")
		return
	}

	body, err := os.ReadFile(cfgFile)
	if err != nil {
		log(a.Name + ": " + err.Error())
		return
	}
	var doc map[string]any
	if err := json.Unmarshal(body, &doc); err != nil {
		log(a.Name + ": config.json is not JSON, leaving its listen address alone")
		return
	}
	scheme, _ := doc["scheme"].(map[string]any)
	if scheme == nil {
		return
	}
	if scheme["address"] == LocalHost && intOf(scheme["http_port"]) == port {
		return
	}
	scheme["address"] = LocalHost
	scheme["http_port"] = port
	doc["scheme"] = scheme

	out, err := json.MarshalIndent(doc, "", "  ")
	if err != nil {
		log(a.Name + ": " + err.Error())
		return
	}
	if err := os.WriteFile(cfgFile, out, 0o644); err != nil {
		log(a.Name + ": " + err.Error())
		return
	}
	log(fmt.Sprintf("%s: listening on %s:%d only", a.Name, LocalHost, port))
	if err := Control(ctx, a, "restart"); err != nil {
		log("restart: " + err.Error())
	}
}

func intOf(v any) int {
	switch n := v.(type) {
	case float64:
		return int(n)
	case int:
		return n
	case string:
		var out int
		fmt.Sscanf(n, "%d", &out)
		return out
	}
	return 0
}

// RewriteUnit writes the service definition again for a new port or domain and
// restarts the application, so its unit and the front's target agree.
func RewriteUnit(ctx context.Context, a App, port int, domain string) error {
	unit, mode := a.UnitContent(port, domain)
	if err := os.WriteFile(a.UnitPath(), []byte(unit), mode); err != nil {
		return err
	}
	if err := service.DaemonReload(); err != nil {
		return err
	}
	return Control(ctx, a, "restart")
}

// PortFree reports whether nothing is listening on the port yet.
func PortFree(port int) bool {
	ln, err := net.Listen("tcp", fmt.Sprintf("127.0.0.1:%d", port))
	if err != nil {
		return false
	}
	ln.Close()
	return true
}

// tail returns the last n lines of a log body.
func tail(body string, n int) string {
	if n <= 0 {
		return body
	}
	var lines []string
	scanner := bufio.NewScanner(strings.NewReader(body))
	scanner.Buffer(make([]byte, 0, 64*1024), 1<<20)
	for scanner.Scan() {
		lines = append(lines, scanner.Text())
	}
	if len(lines) > n {
		lines = lines[len(lines)-n:]
	}
	return strings.Join(lines, "\n")
}

func firstLine(out []byte, err error) string {
	text := strings.TrimSpace(string(out))
	if text == "" {
		if err == nil {
			return ""
		}
		return err.Error()
	}
	if i := strings.IndexByte(text, '\n'); i >= 0 {
		text = text[:i]
	}
	return text
}
