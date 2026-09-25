// Package apps installs and supervises the real applications the panel serves as
// its camouflage site.
//
// The deployment story this package exists for: the operator points a domain at
// the host, the panel reverse-proxies that domain to one of these applications,
// and a probe of the domain therefore lands on a working site — a file list, a
// memo board, a monitoring dashboard — instead of on a proxy port. The
// applications are real: they have their own data, their own web UI and their own
// service, and the operator can use them for their own purposes too.
//
// Every entry is a single-binary Go program published on the upstream GitHub
// releases, which keeps installation to four steps: download the release, verify
// the checksum the upstream project publishes, unpack the one binary, and run it
// as its own service. Nothing is built from source, no container runtime is
// needed, and nothing else is installed on the host.
package apps

import (
	"fmt"
	"os"
	"path"
	"runtime"
	"strconv"
	"strings"

	"github.com/MinimaxFlora/EasySB/internal/service"
)

// Root is the directory applications live under. Each application gets its own
// subdirectory, holding the binary, a VERSION stamp and its data directory.
const Root = "/opt/easysb/apps"

// LocalHost is how the applications are told to bind: the camouflage front is the
// only thing that should be reachable from outside, so an application's own port
// stays on the loopback interface unless the operator deliberately opens it.
const LocalHost = "127.0.0.1"

// Pack is how a release asset is packaged.
type Pack string

const (
	// PackTarGz is a gzipped tarball holding the binary.
	PackTarGz Pack = "tar.gz"
	// PackZip is a zip holding the binary.
	PackZip Pack = "zip"
	// PackRaw is the binary itself, which is how some projects publish Linux
	// builds.
	PackRaw Pack = "raw"
)

// App describes one installable application.
type App struct {
	// ID is the stable identifier used in the panel, in the state file
	// (APP_<ID>_PORT) and in the service name (easysb-<id>).
	ID string
	// Repo is the GitHub repository the releases come from, as owner/name.
	Repo string
	// Asset is the release asset name, with {arch} and {version} placeholders.
	// {version} is the release tag without its leading "v", which is how most
	// projects spell a version in an asset name.
	Asset string
	// Pack is how that asset is packaged.
	Pack Pack
	// SumAsset is the checksum file published next to the asset, and SumKind is
	// how it is spelled. Empty SumAsset means the upstream project publishes no
	// checksum: the download is then verified only by HTTPS and by the archive
	// having to unpack.
	SumAsset string
	SumKind  string
	// File is the binary's name inside the archive. Empty means "the only file in
	// there", which is how dashboards published as a single executable are
	// handled.
	File string
	// Binary is where the binary is installed.
	Binary string
	// Args are the arguments the service runs with. {data} is the application's
	// data directory, {port} its listen port, {host} the loopback host and {url}
	// the public URL of the site.
	Args []string
	// Port is the default listen port.
	Port int
	// Path is where the application's web UI lives under the domain. "/" when the
	// application is the whole site.
	Path string
	// MemoryMB is a rough resident-set hint, used to warn on small machines.
	MemoryMB int
	// Note is the one-line caveat shown next to the application in the panel.
	Note string
	// Name and NameZH are the display names.
	Name   string
	NameZH string
}

// catalog is the list the panel offers, in menu order.
var catalog = []App{
	{
		ID:       "openlist",
		Name:     "OpenList",
		NameZH:   "OpenList 网盘",
		Repo:     "OpenListTeam/OpenList",
		Asset:    "openlist-linux-{arch}.tar.gz",
		Pack:     PackTarGz,
		SumAsset: "md5.txt",
		SumKind:  "md5",
		File:     "openlist",
		Binary:   Root + "/openlist/openlist",
		Args:     []string{"server", "--data", "{data}"},
		Port:     5244,
		Path:     "/",
		MemoryMB: 120,
		Note:     "文件列表站：域名根目录看起来就是一个网盘",
	},
	{
		ID:       "memos",
		Name:     "Memos",
		NameZH:   "Memos 备忘录",
		Repo:     "usememos/memos",
		Asset:    "memos_{version}_linux_{arch}.tar.gz",
		Pack:     PackTarGz,
		SumAsset: "checksums.txt",
		SumKind:  "sha256",
		File:     "memos",
		Binary:   Root + "/memos/memos",
		Args:     []string{"--addr", "{host}", "--port", "{port}", "--data", "{data}", "--instance-url", "{url}"},
		Port:     5230,
		Path:     "/",
		MemoryMB: 90,
		Note:     "备忘/微博客站：最轻，适合小机器",
	},
	{
		ID:       "nezha",
		Name:     "Nezha dashboard",
		NameZH:   "哪吒监控面板",
		Repo:     "nezhahq/nezha",
		Asset:    "dashboard-linux-{arch}.zip",
		Pack:     PackZip,
		File:     "",
		Binary:   Root + "/nezha/dashboard",
		Args:     []string{"-c", "{data}/config.yaml", "-db", "{data}/sqlite.db"},
		Port:     8008,
		Path:     "/",
		MemoryMB: 100,
		Note:     "监控站：上游没有发布校验文件，只按 HTTPS 与解包结果校验",
	},
	{
		ID:       "komari",
		Name:     "Komari",
		NameZH:   "Komari 探针",
		Repo:     "komari-monitor/komari",
		Asset:    "komari-linux-{arch}",
		Pack:     PackRaw,
		File:     "",
		Binary:   Root + "/komari/komari",
		Args:     []string{"server", "-l", "{host}:{port}", "-d", "{data}/komari.db"},
		Port:     25774,
		Path:     "/",
		MemoryMB: 80,
		Note:     "探针站：上游直接发布可执行文件（无压缩包、无校验文件）",
	},
}

// Catalog returns the applications the panel can install.
func Catalog() []App {
	out := make([]App, len(catalog))
	copy(out, catalog)
	return out
}

// Lookup finds an application by its ID.
func Lookup(id string) (App, bool) {
	for _, a := range catalog {
		if a.ID == id {
			return a, true
		}
	}
	return App{}, false
}

// IDs lists the catalogue in menu order.
func IDs() []string {
	out := make([]string, 0, len(catalog))
	for _, a := range catalog {
		out = append(out, a.ID)
	}
	return out
}

// Arch maps this machine onto the architecture name upstream projects use.
func Arch() string { return archFor(runtime.GOARCH) }

func archFor(goarch string) string {
	switch goarch {
	case "amd64":
		return "amd64"
	case "arm64":
		return "arm64"
	case "386":
		return "386"
	case "arm":
		return "armv7"
	}
	return ""
}

// AssetName renders the release asset name for a version.
func (a App) AssetName(version string) string {
	name := strings.ReplaceAll(a.Asset, "{arch}", Arch())
	return strings.ReplaceAll(name, "{version}", strings.TrimPrefix(version, "v"))
}

// AssetURL is the download URL of the release asset for a version.
func (a App) AssetURL(version string) string { return a.releaseURL(version, a.AssetName(version)) }

// SumURL is the download URL of the checksum file, empty when the upstream
// project publishes none.
func (a App) SumURL(version string) string {
	if a.SumAsset == "" {
		return ""
	}
	return a.releaseURL(version, a.SumAsset)
}

func (a App) releaseURL(version, asset string) string {
	return fmt.Sprintf("https://github.com/%s/releases/download/%s/%s", a.Repo, version, asset)
}

// Dir is the application's own directory, DataDir its data directory.
func (a App) Dir() string     { return Root + "/" + a.ID }
func (a App) DataDir() string { return a.Dir() + "/data" }

// ArchivePath is where the downloaded release is unpacked from.
func (a App) ArchivePath() string { return a.Dir() + "/release.part" }

// VersionPath is the sidecar recording which version is installed.
func (a App) VersionPath() string { return a.Dir() + "/VERSION" }

// UnitName is the service name, kept in this project's namespace so it cannot
// collide with a package's own unit.
func (a App) UnitName() string { return "easysb-" + a.ID }

// UnitPath is the service definition for the init system in use.
func (a App) UnitPath() string {
	if service.Detect() == service.OpenRC {
		return "/etc/init.d/" + a.UnitName()
	}
	return "/etc/systemd/system/" + a.UnitName() + ".service"
}

// Command renders the arguments the service runs with for a port and the public
// URL of the site.
func (a App) Command(port int, domain string) []string {
	out := make([]string, 0, len(a.Args))
	for _, arg := range a.Args {
		arg = strings.ReplaceAll(arg, "{data}", a.DataDir())
		arg = strings.ReplaceAll(arg, "{port}", strconv.Itoa(port))
		arg = strings.ReplaceAll(arg, "{host}", LocalHost)
		arg = strings.ReplaceAll(arg, "{url}", PublicURL(domain, a.Path))
		out = append(out, arg)
	}
	return out
}

// PublicURL is the site's address: the domain over https, since the panel only
// ever serves the camouflage site through the domain.
func PublicURL(domain, path string) string {
	if strings.TrimSpace(domain) == "" {
		return ""
	}
	if path == "" {
		path = "/"
	}
	if !strings.HasPrefix(path, "/") {
		path = "/" + path
	}
	if path == "/" {
		return "https://" + domain
	}
	return "https://" + domain + path
}

// ExecStart renders the command line the service runs, for display and for the
// unit file.
func (a App) ExecStart(port int, domain string) string {
	parts := append([]string{a.Binary}, a.Command(port, domain)...)
	return strings.Join(parts, " ")
}

// WebURL is the loopback URL of the application's own web UI.
func (a App) WebURL(port int) string {
	return "http://" + LocalHost + ":" + strconv.Itoa(port) + a.Path
}

// UnitContent renders the service definition for the init system in use. It is a
// method rather than a write so the text is testable without touching /etc.
func (a App) UnitContent(port int, domain string) (string, os.FileMode) {
	if service.Detect() == service.OpenRC {
		return fmt.Sprintf(`#!/sbin/openrc-run
name="%s"
description="%s (EasySB camouflage site)"
command="%s"
command_args="%s"
directory="%s"
command_background=true
pidfile="/run/${RC_SVCNAME}.pid"
output_log="/var/log/%s.log"
error_log="/var/log/%s.log"
`, a.Name, a.Name, a.Binary, strings.Join(a.Command(port, domain), " "), a.Dir(), a.UnitName(), a.UnitName()), 0o755
	}
	return fmt.Sprintf(`[Unit]
Description=%s (EasySB camouflage site)
After=network.target

[Service]
Type=simple
WorkingDirectory=%s
ExecStart=%s
Restart=on-failure
RestartSec=3
LimitNOFILE=infinity

[Install]
WantedBy=multi-user.target
`, a.Name, a.Dir(), a.ExecStart(port, domain)), 0o644
}

// Checksum picks this asset's checksum out of a checksum file. Both spellings in
// the wild are handled: "hash  name" and "hash *name", with the name possibly
// carrying a path.
func Checksum(body, asset string) string {
	for _, line := range strings.Split(body, "\n") {
		fields := strings.Fields(strings.TrimSpace(line))
		if len(fields) < 2 {
			continue
		}
		name := strings.TrimPrefix(strings.TrimPrefix(fields[len(fields)-1], "*"), "./")
		if path.Base(name) != asset {
			continue
		}
		return strings.ToLower(fields[0])
	}
	return ""
}
