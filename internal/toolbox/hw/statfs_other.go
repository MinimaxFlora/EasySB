//go:build !linux

package hw

import "errors"

// Statfs has no portable implementation. The stub keeps this package buildable and
// testable on a development host that is not the Linux target; a caller there reports
// the mount's free space as unreadable instead of guessing at it.
func (osFS) Statfs(string) (uint64, uint64, error) {
	return 0, 0, errors.New("剩余空间只在 Linux 上读取（statfs 不可用）")
}
