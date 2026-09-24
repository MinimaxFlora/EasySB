//go:build linux

package bbr

import (
	"context"
	"os"
	"strings"
	"testing"
	"time"
)

// TestCollectOnThisMachine exercises the reads the status screen performs, on the
// machine the test runs on: the values themselves depend on the host, what matters
// is that every reading comes back instead of hanging or panicking.
func TestCollectOnThisMachine(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), time.Minute)
	defer cancel()

	st := Collect(ctx)
	t.Logf("kernel=%q congestion=%q available=%q qdisc=%q arch=%q kernels=%v latest=%q err=%q",
		st.Running, st.Congestion, st.Available, st.Qdisc, st.Arch, st.Kernels, st.Latest, st.LatestErr)
	if st.Running == "" {
		t.Error("uname -r came back empty")
	}
	if st.Congestion == "" {
		t.Error("the congestion control reading is empty")
	}
	if st.Arch == "" {
		t.Log("this architecture has no published kernel")
	}
	if st.Enabled() && !st.AvailableBBR() {
		t.Error("bbr is running but the available list does not carry it")
	}
}

// TestEnableAndClearRoundTrip changes the real congestion control, so it only runs
// when it is asked for. It is the test that proves the drop-ins, the module load
// and the undo work on a real kernel, and it leaves the machine as it found it.
func TestEnableAndClearRoundTrip(t *testing.T) {
	if os.Getenv("EASYSB_BBR_WRITE") == "" {
		t.Skip("set EASYSB_BBR_WRITE=1 to change this machine's congestion control")
	}
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Minute)
	defer cancel()

	before := captureSettings(ctx)
	log := func(line string) { t.Log(line) }

	if err := Enable(ctx, log, "fq"); err != nil {
		// A kernel without the bbr module is a legitimate answer: what would be
		// a bug is failing for any other reason.
		if !strings.Contains(" "+sysctlGet(ctx, "net.ipv4.tcp_available_congestion_control")+" ", " bbr ") {
			t.Skipf("this kernel has no bbr module: %v", err)
		}
		t.Fatalf("Enable failed on a kernel that offers bbr: %v", err)
	}
	if got := sysctlGet(ctx, "net.ipv4.tcp_congestion_control"); got != "bbr" {
		t.Fatalf("after Enable the congestion control is %q", got)
	}
	if got := sysctlGet(ctx, "net.core.default_qdisc"); got != "fq" {
		t.Fatalf("after Enable the queue discipline is %q", got)
	}
	// The drop-in has to carry the undo note, or clearing cannot restore anything.
	if _, err := os.Stat(SysctlConf); err != nil {
		t.Fatalf("no drop-in was written: %v", err)
	}
	if readPrevious(SysctlConf) == (previousSettings{}) {
		t.Fatal("the drop-in does not record what it replaced")
	}

	cleared, err := Clear(ctx, log)
	if err != nil {
		t.Fatalf("Clear: %v", err)
	}
	if !cleared {
		t.Fatal("Clear reported nothing to clear after Enable")
	}
	for _, path := range []string{SysctlConf, ModulesConf} {
		if _, err := os.Stat(path); err == nil {
			t.Fatalf("%s survived the clear", path)
		}
	}
	if got := sysctlGet(ctx, "net.ipv4.tcp_congestion_control"); got != before.congestion {
		t.Fatalf("after Clear the congestion control is %q, want the recorded %q", got, before.congestion)
	}
	if before.qdisc != "" {
		if got := sysctlGet(ctx, "net.core.default_qdisc"); got != before.qdisc {
			t.Fatalf("after Clear the queue discipline is %q, want the recorded %q", got, before.qdisc)
		}
	}
}
