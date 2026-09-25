package service

import (
	"strings"
	"testing"

	"github.com/MinimaxFlora/EasySB/internal/sysinfo"
)

// The node is this binary, so the unit has to name the panel and the core subcommand:
// pointing at /etc/sing-box/sing-box is what the old design needed and would now start
// nothing.
func TestUnitRunsThePanelAsTheCore(t *testing.T) {
	const exe = "/usr/local/bin/easysb"
	cases := []struct {
		name    string
		manager Manager
		want    []string
		reject  []string
	}{
		{
			name:    "systemd",
			manager: Systemd,
			want: []string{
				"ExecStart=" + exe + " core run -c " + sysinfo.ConfigJSON,
				"[Install]",
			},
			reject: []string{sysinfo.CoreBin + " run"},
		},
		{
			name:    "openrc",
			manager: OpenRC,
			want: []string{
				`command="` + exe + `"`,
				`command_args="core run -c ` + sysinfo.ConfigJSON + `"`,
			},
			reject: []string{"command=\"" + sysinfo.CoreBin + "\""},
		},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			unit, _ := unitContent(tc.manager, exe)
			for _, want := range tc.want {
				if !strings.Contains(unit, want) {
					t.Errorf("unit does not contain %q:\n%s", want, unit)
				}
			}
			for _, reject := range tc.reject {
				if strings.Contains(unit, reject) {
					t.Errorf("unit still points at the old core binary (%q):\n%s", reject, unit)
				}
			}
		})
	}
}

// The service name and the unit path stay as they were: the boot unit of the port-hopping
// rules is ordered before sing-box.service, and the state file records the same name.
func TestUnitIdentityIsUnchanged(t *testing.T) {
	if sysinfo.ServiceName != "sing-box" {
		t.Fatalf("ServiceName = %q, want sing-box", sysinfo.ServiceName)
	}
	unit, _ := unitContent(Systemd, "/usr/local/bin/easysb")
	if !strings.Contains(unit, "Description=sing-box service (EasySB)") {
		t.Errorf("systemd unit lost its description:\n%s", unit)
	}
}
