//go:build linux

package hw

import "syscall"

// Statfs reports the size and the space available to an unprivileged process for the
// filesystem holding path — the size and avail columns of df. Bavail is used rather
// than Bfree because root-reserved blocks are not available to the workloads the
// operator is sizing this host for.
func (osFS) Statfs(path string) (uint64, uint64, error) {
	var st syscall.Statfs_t
	if err := syscall.Statfs(path, &st); err != nil {
		return 0, 0, err
	}
	return st.Blocks * uint64(st.Bsize), st.Bavail * uint64(st.Bsize), nil
}
