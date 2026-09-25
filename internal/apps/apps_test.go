package apps

import (
	"strings"
	"testing"
)

// The asset name is what decides whether an install works at all, so it is spelled
// out per project: two of the four put no version in the name, one spells it without
// the leading "v", and one publishes a bare executable.
func TestAssetNames(t *testing.T) {
	cases := []struct {
		id      string
		version string
		want    string
	}{
		{"openlist", "v4.2.6", "openlist-linux-amd64.tar.gz"},
		{"memos", "v0.31.0", "memos_0.31.0_linux_amd64.tar.gz"},
		{"nezha", "v2.3.13", "dashboard-linux-amd64.zip"},
		{"komari", "1.5.1", "komari-linux-amd64"},
	}
	for _, c := range cases {
		app, ok := Lookup(c.id)
		if !ok {
			t.Fatalf("catalogue is missing %q", c.id)
		}
		if got := app.AssetName(c.version); got != c.want {
			t.Errorf("%s asset = %q, want %q", c.id, got, c.want)
		}
	}
}

// Every application is installed from its own repository and unpacked by the packer
// the release uses.
func TestCatalogueIsComplete(t *testing.T) {
	for _, app := range Catalog() {
		if app.Repo == "" || app.Asset == "" || app.Binary == "" || app.Port == 0 {
			t.Errorf("%s: incomplete catalogue entry %+v", app.ID, app)
		}
		if app.Binary != app.Dir()+"/"+app.ID && app.ID != "nezha" {
			t.Errorf("%s: binary %q is not in %q", app.ID, app.Binary, app.Dir())
		}
		switch app.Pack {
		case PackTarGz, PackZip, PackRaw:
		default:
			t.Errorf("%s: unknown packaging %q", app.ID, app.Pack)
		}
		if app.UnitName() != "easysb-"+app.ID {
			t.Errorf("%s: unit name %q is not namespaced", app.ID, app.UnitName())
		}
	}
}

// A checksum file is only useful when the right line is picked out of it, which is
// what decides whether a download is accepted.
func TestChecksumPicking(t *testing.T) {
	body := strings.Join([]string{
		"# a comment",
		"aaaa  other-linux-amd64.tar.gz",
		"bbbb  openlist-linux-amd64.tar.gz",
		"cccc *memos_0.31.0_linux_amd64.tar.gz",
		"",
	}, "\n")

	if got := Checksum(body, "openlist-linux-amd64.tar.gz"); got != "bbbb" {
		t.Errorf("openlist checksum = %q, want bbbb", got)
	}
	if got := Checksum(body, "memos_0.31.0_linux_amd64.tar.gz"); got != "cccc" {
		t.Errorf("memos checksum = %q, want cccc (the binary marker)", got)
	}
	if got := Checksum(body, "missing.tar.gz"); got != "" {
		t.Errorf("missing checksum = %q, want empty", got)
	}
}

// The command line is what the service runs, so the placeholders have to be filled
// with the paths the installer created — and the application has to be told to bind
// loopback, because the front is the only thing meant to be reachable.
func TestCommandFillsPlaceholders(t *testing.T) {
	memos, _ := Lookup("memos")
	cmd := memos.Command(5230, "us.example.com")
	joined := strings.Join(cmd, " ")
	for _, want := range []string{
		"--addr " + LocalHost,
		"--port 5230",
		"--data " + memos.DataDir(),
		"--instance-url https://us.example.com",
	} {
		if !strings.Contains(joined, want) {
			t.Errorf("memos command %q is missing %q", joined, want)
		}
	}
	if strings.Contains(joined, "{") {
		t.Errorf("memos command %q still has a placeholder", joined)
	}

	openlist, _ := Lookup("openlist")
	if got := strings.Join(openlist.Command(5244, "us.example.com"), " "); got != "server --data "+openlist.DataDir() {
		t.Errorf("openlist command = %q", got)
	}
}

// The unit is how the application survives a reboot, and its paths have to be the
// ones the installer wrote.
func TestUnitContentNamesTheApplication(t *testing.T) {
	app, _ := Lookup("openlist")
	unit, mode := app.UnitContent(5244, "us.example.com")
	for _, want := range []string{
		"ExecStart=" + app.Binary,
		"WorkingDirectory=" + app.Dir(),
		"WantedBy=multi-user.target",
	} {
		if !strings.Contains(unit, want) {
			t.Errorf("unit is missing %q:\n%s", want, unit)
		}
	}
	if !strings.HasSuffix(app.UnitPath(), "easysb-openlist.service") {
		t.Errorf("unit path = %q", app.UnitPath())
	}
	if mode != 0o644 {
		t.Errorf("systemd unit mode = %o, want 644", mode)
	}
}

// The archive entry that gets installed is the binary, not a README next to it: the
// dashboard releases ship the executable under the asset's own name, and the others
// ship a file called after the application.
func TestWantedEntry(t *testing.T) {
	nezha, _ := Lookup("nezha")
	if !nezha.wanted("dashboard-linux-amd64") {
		t.Error("nezha should accept its published executable name")
	}
	if nezha.wanted("README.md") {
		t.Error("nezha should not accept a README")
	}
	openlist, _ := Lookup("openlist")
	if !openlist.wanted("openlist") {
		t.Error("openlist should accept its binary")
	}
	if openlist.wanted("openlist.service") {
		t.Error("openlist should not accept a unit file from the archive")
	}
}

// An application that cannot be pinned to loopback has to say so: the panel's promise
// is that only the front is reachable, and Nezha's upstream offers no bind option.
func TestBindsAllInterfacesIsRecorded(t *testing.T) {
	nezha, _ := Lookup("nezha")
	if !nezha.BindsAllInterfaces {
		t.Error("nezha should be marked as binding every interface")
	}
	for _, app := range Catalog() {
		if app.ID != "nezha" && app.BindsAllInterfaces {
			t.Errorf("%s: only nezha is known to lack a bind option", app.ID)
		}
	}
}

// The public URL is what an application is told about itself, and it is always the
// https address of the domain: the panel does not serve a plaintext site.
func TestPublicURL(t *testing.T) {
	if got := PublicURL("us.example.com", "/"); got != "https://us.example.com" {
		t.Errorf("root url = %q", got)
	}
	if got := PublicURL("us.example.com", "/sub/"); got != "https://us.example.com/sub/" {
		t.Errorf("sub url = %q", got)
	}
	if got := PublicURL("", "/"); got != "" {
		t.Errorf("url without a domain = %q, want empty", got)
	}
}
