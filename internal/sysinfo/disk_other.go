//go:build !linux

package sysinfo

// diskUsage has no portable implementation. The stub exists so the packages
// that embed sysinfo (state, user, subscribe, tui) can be compiled and unit
// tested on a development host that is not the Linux target; the panel simply
// prints no disk figures there.
func diskUsage(string) (uint64, uint64) {
	return 0, 0
}
