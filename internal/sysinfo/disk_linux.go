//go:build linux

package sysinfo

import "syscall"

// diskUsage returns the total and available bytes of the filesystem holding
// path.
func diskUsage(path string) (uint64, uint64) {
	var st syscall.Statfs_t
	if err := syscall.Statfs(path, &st); err != nil {
		return 0, 0
	}
	return st.Blocks * uint64(st.Bsize), st.Bavail * uint64(st.Bsize)
}
