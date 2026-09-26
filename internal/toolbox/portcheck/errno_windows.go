//go:build windows

package portcheck

import "syscall"

// errnoConnRefused is the errno a peer's RST produces on Windows:
// WSAECONNREFUSED. The syscall package does not export the Windows socket
// constants, and Windows' own ECONNREFUSED is a fabricated value no dial error
// ever carries, so the number is spelled out next to its name.
const errnoConnRefused = syscall.Errno(10061)
