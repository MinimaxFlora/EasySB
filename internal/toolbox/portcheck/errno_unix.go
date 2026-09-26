//go:build !windows

package portcheck

import "syscall"

// errnoConnRefused is the errno a peer's RST produces on Unix.
const errnoConnRefused = syscall.ECONNREFUSED
