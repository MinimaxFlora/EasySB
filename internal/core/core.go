// Package core manages the sing-box core binary: querying releases, downloading
// and installing the official build, plus the small helper subcommands that only
// the core can provide (Reality keypair, UUID, config check).
package core

import (
	"archive/tar"
	"compress/gzip"
	"context"
	"crypto/rand"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"os"
	"os/exec"
	"path"
	"regexp"
	"runtime"
	"strings"
	"time"

	"github.com/MinimaxFlora/EasySB/internal/sbcore"
	"github.com/MinimaxFlora/EasySB/internal/sysinfo"
)

const (
	// Repo is the upstream sing-box repository: the fallback source, used for a channel
	// this repository has not published a rebuilt core for yet.
	Repo = "SagerNet/sing-box"
	// API lists releases on the upstream repository.
	API = "https://api.github.com/repos/" + Repo + "/releases"
	// Web is the human facing releases page.
	Web = "https://github.com/" + Repo

	// BuildRepo publishes the panel's own cores: the same upstream source compiled with
	// the with_v2ray_api tag the official releases leave out, one rolling release per
	// channel holding the archives plus a version.ini stamp. See docs/core-builds.md.
	BuildRepo = "MinimaxFlora/EasySB"

	// SourceBuild and SourceUpstream say which of the two an offered core came from.
	// Only the rebuilt one carries the counters per-account accounting reads.
	SourceBuild    = "build"
	SourceUpstream = "upstream"
)

// ChannelTag is the release tag holding a channel's rebuilt core.
func ChannelTag(channel string) string {
	return "singbox-" + channel
}

// StampURL is the version stamp of a channel's rebuilt core: written last, after every
// architecture archive of that version is attached.
func StampURL(channel string) string {
	return fmt.Sprintf("https://github.com/%s/releases/download/%s/version.ini", BuildRepo, ChannelTag(channel))
}

// BuildAssetURL builds the archive URL of a channel's rebuilt core. The file name is the
// official one on purpose: switching source is a change of repository and tag, not a
// second download path.
func BuildAssetURL(channel, version, arch string) string {
	return fmt.Sprintf("https://github.com/%s/releases/download/%s/sing-box-%s-linux-%s.tar.gz",
		BuildRepo, ChannelTag(channel), version, arch)
}

// parseStamp reads one key out of a version.ini stamp, ignoring sections and comments.
func parseStamp(body []byte, key string) string {
	for _, line := range strings.Split(string(body), "\n") {
		line = strings.TrimSpace(line)
		if line == "" || strings.HasPrefix(line, "[") || strings.HasPrefix(line, "#") {
			continue
		}
		name, value, ok := strings.Cut(line, "=")
		if ok && strings.TrimSpace(name) == key {
			return strings.TrimSpace(value)
		}
	}
	return ""
}

// FetchBuildRelease reads a channel's rebuilt core from this repository's version stamp.
func FetchBuildRelease(ctx context.Context, channel string) (Release, error) {
	body, err := fetch(ctx, StampURL(channel))
	if err != nil {
		return Release{}, err
	}
	version := parseStamp(body, "version")
	if version == "" {
		return Release{}, errors.New("version stamp carries no version")
	}
	return Release{
		Version: version,
		Tag:     ChannelTag(channel),
		URL:     BuildAssetURL(channel, version, Arch()),
		Source:  SourceBuild,
	}, nil
}

// Release describes one downloadable core build.
type Release struct {
	Version string
	Tag     string
	URL     string
	// Source is SourceBuild or SourceUpstream, so the caller can say where the core
	// came from and warn when it cannot count traffic.
	Source string
}

// Releases holds the newest stable and alpha builds.
type Releases struct {
	Stable Release
	Alpha  Release
}

// Installed reports whether this host can run a node. The core is this binary — the panel
// is compiled with the sing-box library — so the answer is always yes, and the guard
// stays because the deploy path asks it before writing a config.
func Installed() bool { return true }

// LocalVersion returns the sing-box version this binary carries. ctx is unused now that
// the version is a value in the binary instead of a `sing-box version` subprocess; the
// signature stays so callers did not have to change.
func LocalVersion(ctx context.Context) string { return sbcore.Version() }

// InstalledChannel returns the channel recorded in state, falling back to an
// inference from the version string (alpha/beta/rc implies the alpha channel).
func InstalledChannel(stateChannel string) string {
	if stateChannel != "" {
		return stateChannel
	}
	v := strings.ToLower(LocalVersion(context.Background()))
	if strings.Contains(v, "alpha") || strings.Contains(v, "beta") || strings.Contains(v, "rc") {
		return "alpha"
	}
	return "stable"
}

// ArchFromUname maps `uname -m` output to the sing-box release architecture.
func ArchFromUname(machine string) string {
	switch strings.ToLower(strings.TrimSpace(machine)) {
	case "x86_64", "amd64":
		return "amd64"
	case "aarch64", "arm64":
		return "arm64"
	case "armv7l", "armv7":
		return "armv7"
	case "armv6l", "armv6":
		return "armv6"
	case "i386", "i486", "i586", "i686":
		return "386"
	case "s390x":
		return "s390x"
	case "riscv64":
		return "riscv64"
	case "mips":
		return "mips"
	case "mips64":
		return "mips64"
	case "mips64el":
		return "mips64le"
	case "mipsel":
		return "mipsle"
	case "ppc64le":
		return "ppc64le"
	default:
		return ""
	}
}

func archFromGOARCH(goarch string) string {
	switch goarch {
	case "arm":
		return "armv7"
	default:
		return goarch
	}
}

// Arch returns the architecture used in release asset names.
func Arch() string {
	if out, err := exec.Command("uname", "-m").Output(); err == nil {
		if a := ArchFromUname(string(out)); a != "" {
			return a
		}
	}
	return archFromGOARCH(runtime.GOARCH)
}

// AssetURL builds the official archive URL for a tag and architecture.
func AssetURL(tag, arch string) string {
	return fmt.Sprintf("https://github.com/%s/releases/download/%s/sing-box-%s-linux-%s.tar.gz",
		Repo, tag, strings.TrimPrefix(tag, "v"), arch)
}

type ghAsset struct {
	Name string `json:"name"`
	URL  string `json:"browser_download_url"`
}

type ghRelease struct {
	Tag        string    `json:"tag_name"`
	Draft      bool      `json:"draft"`
	Prerelease bool      `json:"prerelease"`
	Assets     []ghAsset `json:"assets"`
}

// selectRelease picks the newest matching release from an API payload.
func selectRelease(rels []ghRelease, prerelease bool, arch string) Release {
	suffix := "linux-" + arch + ".tar.gz"
	for _, r := range rels {
		if r.Draft || r.Prerelease != prerelease {
			continue
		}
		rel := Release{Version: strings.TrimPrefix(r.Tag, "v"), Tag: r.Tag, Source: SourceUpstream}
		for _, a := range r.Assets {
			if strings.HasSuffix(a.Name, suffix) {
				rel.URL = a.URL
				break
			}
		}
		if rel.URL == "" {
			rel.URL = AssetURL(r.Tag, arch)
		}
		return rel
	}
	return Release{}
}

// FetchReleases queries the newest official stable and alpha core builds. The official
// builds are compiled without the V2Ray API, so a deployment on one of them carries no
// traffic counters; this is the escape hatch, and FetchPreferred is the normal path.
func FetchReleases(ctx context.Context) (Releases, error) {
	return fetchUpstream(ctx)
}

// FetchPreferred returns the newest stable and alpha cores, taking each channel from this
// repository's rebuilt release when it has one and falling back to the official release
// otherwise. The rebuilt source is what per-account accounting needs: the official builds
// leave out the with_v2ray_api tag, and a core without it cannot be given a config that
// names the API.
func FetchPreferred(ctx context.Context) (Releases, error) {
	out := Releases{}
	missing := false
	for _, channel := range []string{"stable", "alpha"} {
		rel, err := FetchBuildRelease(ctx, channel)
		if err == nil && rel.Version != "" {
			if channel == "stable" {
				out.Stable = rel
			} else {
				out.Alpha = rel
			}
			continue
		}
		missing = true
	}
	if missing {
		upstream, err := fetchUpstream(ctx)
		if out.Stable.Version == "" {
			out.Stable = upstream.Stable
		}
		if out.Alpha.Version == "" {
			out.Alpha = upstream.Alpha
		}
		if out.Stable.Version == "" && out.Alpha.Version == "" {
			if err != nil {
				return out, err
			}
			return out, errors.New("no releases available")
		}
	}
	return out, nil
}

// fetchUpstream queries the newest stable and alpha core builds on the official
// repository, which is also the fallback for a channel without a rebuilt core.
func fetchUpstream(ctx context.Context) (Releases, error) {
	var rels []ghRelease
	body, err := fetch(ctx, API+"?per_page=40")
	if err == nil {
		if err := json.Unmarshal(body, &rels); err != nil {
			rels = nil
		}
	}

	out := Releases{
		Stable: selectRelease(rels, false, Arch()),
		Alpha:  selectRelease(rels, true, Arch()),
	}
	if out.Stable.Version == "" {
		if tag, err := fetchLatestTag(ctx); err == nil {
			out.Stable = Release{Version: strings.TrimPrefix(tag, "v"), Tag: tag, URL: AssetURL(tag, Arch()), Source: SourceUpstream}
		}
	}
	if out.Alpha.Version == "" {
		if tag, err := fetchAlphaTag(ctx); err == nil {
			out.Alpha = Release{Version: strings.TrimPrefix(tag, "v"), Tag: tag, URL: AssetURL(tag, Arch()), Source: SourceUpstream}
		}
	}
	if out.Stable.Version == "" && out.Alpha.Version == "" {
		if err != nil {
			return out, err
		}
		return out, errors.New("no releases available")
	}
	return out, nil
}

// fetchLatestTag follows the /releases/latest redirect to read the stable tag.
func fetchLatestTag(ctx context.Context) (string, error) {
	client := &http.Client{
		Timeout: 12 * time.Second,
		CheckRedirect: func(*http.Request, []*http.Request) error {
			return http.ErrUseLastResponse
		},
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodHead, "https://github.com/"+Repo+"/releases/latest", nil)
	if err != nil {
		return "", err
	}
	req.Header.Set("User-Agent", "EasySB")
	resp, err := client.Do(req)
	if err != nil {
		return "", err
	}
	resp.Body.Close()
	if loc := resp.Header.Get("Location"); loc != "" {
		if tag := path.Base(loc); tag != "" && tag != "latest" {
			return normalizeTag(tag), nil
		}
	}
	return "", errors.New("no redirect from latest release")
}

var alphaTagRe = regexp.MustCompile(`<title>(v?[0-9][^<]*(?:alpha|beta|rc)[^<]*)</title>`)

func fetchAlphaTag(ctx context.Context) (string, error) {
	body, err := fetch(ctx, "https://github.com/"+Repo+"/releases.atom")
	if err != nil {
		return "", err
	}
	if m := alphaTagRe.FindSubmatch(body); len(m) == 2 {
		return normalizeTag(string(m[1])), nil
	}
	return "", errors.New("no alpha release found")
}

// normalizeTag restores the conventional "v" prefix on a release tag. The
// releases.atom feed reports sing-box tags without it (1.15.0-alpha.6), but the
// download path and archive name expect the real tag (v1.15.0-alpha.6).
func normalizeTag(tag string) string {
	if tag == "" || tag[0] < '0' || tag[0] > '9' {
		return tag
	}
	return "v" + tag
}

// fetch returns the body of a GitHub URL.
func fetch(ctx context.Context, url string) ([]byte, error) {
	body, err := get(ctx, url)
	if err != nil {
		return nil, err
	}
	if len(body) == 0 {
		return nil, errors.New("empty response")
	}
	return body, nil
}

func get(ctx context.Context, url string) ([]byte, error) {
	cctx, cancel := context.WithTimeout(ctx, 15*time.Second)
	defer cancel()
	req, err := http.NewRequestWithContext(cctx, http.MethodGet, url, nil)
	if err != nil {
		return nil, err
	}
	req.Header.Set("User-Agent", "EasySB")
	req.Header.Set("Accept", "application/vnd.github+json")
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("GET %s: %s", url, resp.Status)
	}
	return io.ReadAll(io.LimitReader(resp.Body, 8<<20))
}

// Progress reports a download in flight: the file being fetched, how many bytes have
// arrived and the size the server announced (0 when it sends no length). It is called
// from the goroutine doing the download, at most every downloadTick.
type Progress func(label string, done, total int64)

// downloadTick is how often a download reports itself. Ten readings a second is smooth
// on a terminal and costs nothing next to a 100 MB kernel package.
const downloadTick = 100 * time.Millisecond

// countingBody wraps a response body and reports how much of it has been read.
type countingBody struct {
	body   io.Reader
	report Progress
	label  string
	total  int64
	done   int64
	last   time.Time
}

func (c *countingBody) Read(b []byte) (int, error) {
	n, err := c.body.Read(b)
	if n > 0 {
		c.done += int64(n)
		now := time.Now()
		if c.last.IsZero() || now.Sub(c.last) >= downloadTick {
			c.last = now
			c.emit()
		}
	}
	return n, err
}

// emit sends one reading, if there is a listener. The reader runs on the download
// goroutine, so the callback has to be cheap and has to tolerate being called from
// there.
func (c *countingBody) emit() {
	if c.report != nil {
		c.report(c.label, c.done, c.total)
	}
}

// Download streams a URL to dest, with the budget a core tarball needs.
func Download(ctx context.Context, url, dest string) error {
	return DownloadWithProgress(ctx, url, dest, 5*time.Minute, nil)
}

// DownloadWithin is Download with an explicit budget, for the callers that pull
// something much larger than a core tarball.
func DownloadWithin(ctx context.Context, url, dest string, timeout time.Duration) error {
	return DownloadWithProgress(ctx, url, dest, timeout, nil)
}

// DownloadWithProgress is the whole download path: it streams url to dest and reports
// the bytes as they arrive to progress. A nil progress means the caller only wants the
// file, which is what the non-interactive entry points do.
func DownloadWithProgress(ctx context.Context, url, dest string, timeout time.Duration, progress Progress) error {
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, url, nil)
	if err != nil {
		return err
	}
	req.Header.Set("User-Agent", "EasySB")

	client := &http.Client{Timeout: timeout}
	resp, err := client.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return fmt.Errorf("download %s: %s", url, resp.Status)
	}

	f, err := os.Create(dest)
	if err != nil {
		return err
	}
	defer f.Close()
	body := &countingBody{body: resp.Body, report: progress, label: path.Base(url), total: resp.ContentLength}
	if _, err := io.Copy(f, body); err != nil {
		return err
	}
	// The last tick may have been up to downloadTick before the end, so the finished
	// download reports its final size rather than a percentage short of 100.
	body.emit()
	return f.Sync()
}

// ExtractBinary reads a sing-box tar.gz archive and installs its binary to
// dest (mode 0755), replacing any existing file atomically.
func ExtractBinary(archivePath, dest string) error {
	f, err := os.Open(archivePath)
	if err != nil {
		return err
	}
	defer f.Close()
	return extractTarGz(f, dest)
}

// extractTarGz installs the sing-box binary out of an open archive stream, which is
// what both a downloaded tarball and the archive a build carries go through.
func extractTarGz(r io.Reader, dest string) error {
	gz, err := gzip.NewReader(r)
	if err != nil {
		return err
	}
	defer gz.Close()

	tr := tar.NewReader(gz)
	tmp := dest + ".new"
	for {
		hdr, err := tr.Next()
		if err == io.EOF {
			break
		}
		if err != nil {
			return err
		}
		if hdr.Typeflag != tar.TypeReg || path.Base(hdr.Name) != "sing-box" {
			continue
		}
		out, err := os.OpenFile(tmp, os.O_CREATE|os.O_TRUNC|os.O_WRONLY, 0o755)
		if err != nil {
			return err
		}
		if _, err := io.Copy(out, tr); err != nil {
			out.Close()
			return err
		}
		if err := out.Close(); err != nil {
			return err
		}
		return os.Rename(tmp, dest)
	}
	return errors.New("sing-box binary not found in archive")
}

// Install downloads and installs the given release, returning its version. The
// download reports itself to progress so the panel can show a bar while a core
// tarball is on its way.
func Install(ctx context.Context, rel Release, log func(string), progress Progress) (string, error) {
	if rel.Version == "" || rel.URL == "" {
		return "", errors.New("no available version on this channel")
	}
	if err := os.MkdirAll(sysinfo.WorkDir, 0o755); err != nil {
		return "", err
	}
	log("GET " + rel.URL)
	tmp := fmt.Sprintf("%s/sing-box-%s.tar.gz", os.TempDir(), rel.Version)
	if err := DownloadWithProgress(ctx, rel.URL, tmp, 5*time.Minute, progress); err != nil {
		return "", err
	}
	defer os.Remove(tmp)

	log("extract -> " + sysinfo.CoreBin)
	if err := ExtractBinary(tmp, sysinfo.CoreBin); err != nil {
		return "", err
	}
	return rel.Version, nil
}

// SupportsV2RayStats reports whether this build can count per-account traffic, which the
// counters read from the core's V2Ray API (experimental.v2ray_api) over gRPC. The panel
// ships its own build now, so this is a property of the build tags rather than something
// probed off a downloaded binary: with_v2ray_api is on in every release.
func SupportsV2RayStats(ctx context.Context) bool { return sbcore.StatsAvailable() }

// RealityKeypair returns a fresh Reality private/public key pair, generated in-process and
// encoded exactly the way sing-box clients expect.
func RealityKeypair(ctx context.Context) (string, string, error) { return sbcore.RealityKeypair() }

// GenerateUUID returns a v4 UUID for a new inbound or account credential. The core is in
// this process now, so there is no subprocess to ask.
func GenerateUUID(ctx context.Context) string { return randomUUID() }

func randomUUID() string {
	var b [16]byte
	if _, err := rand.Read(b[:]); err != nil {
		return ""
	}
	b[6] = (b[6] & 0x0f) | 0x40
	b[8] = (b[8] & 0x3f) | 0x80
	return fmt.Sprintf("%x-%x-%x-%x-%x", b[0:4], b[4:6], b[6:8], b[8:10], b[10:16])
}

// ConfigCheck validates a sing-box config with the core this binary carries: the file is
// decoded and an instance is built and closed again, so a config naming an API or a
// protocol this build does not carry fails here rather than at service start.
func ConfigCheck(ctx context.Context, configPath string) bool {
	if _, err := os.Stat(configPath); err != nil {
		return false
	}
	return sbcore.Check(configPath) == nil
}

func run(ctx context.Context, name string, args ...string) (string, error) {
	cctx, cancel := context.WithTimeout(ctx, 10*time.Second)
	defer cancel()
	cmd := exec.CommandContext(cctx, name, args...)
	cmd.Env = append(os.Environ(), "LC_ALL=C")
	out, err := cmd.CombinedOutput()
	return string(out), err
}
