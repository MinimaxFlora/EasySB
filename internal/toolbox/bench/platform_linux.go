//go:build linux

package bench

import (
	"errors"
	"os"
	"strconv"
	"strings"
	"syscall"
)

// freeSpace reports the bytes still writable on the file system holding dir.
//
// The second result is false when the platform cannot answer, and the caller then skips the
// capacity check instead of refusing to run: a benchmark that cannot size its file is still
// a benchmark, while a benchmark that fills a system partition is an incident.
func freeSpace(dir string) (int64, bool) {
	var st syscall.Statfs_t
	if err := syscall.Statfs(dir, &st); err != nil {
		return 0, false
	}
	return int64(st.Bavail) * int64(st.Bsize), true
}

// availableMemory reports what the kernel says it can hand out without swapping, in bytes.
// MemAvailable is the honest figure; MemFree is the fallback for kernels that predate it and
// it is pessimistic, which is the safe direction for a buffer size.
func availableMemory() (int64, bool) {
	data, err := os.ReadFile("/proc/meminfo")
	if err != nil {
		return 0, false
	}
	var free int64
	for _, line := range strings.Split(string(data), "\n") {
		key, value, ok := strings.Cut(line, ":")
		if !ok {
			continue
		}
		switch strings.TrimSpace(key) {
		case "MemAvailable":
			if n, err := parseKiB(value); err == nil {
				return n, true
			}
		case "MemFree":
			if n, err := parseKiB(value); err == nil {
				free = n
			}
		}
	}
	if free > 0 {
		return free, true
	}
	return 0, false
}

// parseKiB reads a /proc value such as "  16334832 kB".
func parseKiB(value string) (int64, error) {
	fields := strings.Fields(value)
	if len(fields) == 0 {
		return 0, errors.New("no value")
	}
	n, err := strconv.ParseInt(fields[0], 10, 64)
	if err != nil {
		return 0, err
	}
	return n * 1024, nil
}
