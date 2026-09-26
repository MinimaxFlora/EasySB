package hw

import (
	"fmt"
	"strconv"
	"strings"
	"time"
)

// humanBytes renders a byte count in binary units the way df -h does: one decimal
// below ten so 7.8 GiB and 38 GiB both read naturally.
func humanBytes(n uint64) string {
	const unit = 1024
	if n < unit {
		return fmt.Sprintf("%d B", n)
	}
	units := []string{"KiB", "MiB", "GiB", "TiB", "PiB", "EiB"}
	value := float64(n)
	i := -1
	for value >= unit && i < len(units)-1 {
		value /= unit
		i++
	}
	if value < 10 {
		return fmt.Sprintf("%.1f %s", value, units[i])
	}
	return fmt.Sprintf("%.0f %s", value, units[i])
}

// cacheSize renders a kernel cache size. The kernel always prints it in K
// ("32K", "1536K", "36864K"); the table shows MiB once a level reaches one, which is
// what makes "L3 35M" readable next to "L1d 32K".
func cacheSize(text string) string {
	text = strings.TrimSpace(text)
	if text == "" {
		return ""
	}
	digits, suffix := text, ""
	for i, r := range text {
		if r < '0' || r > '9' {
			digits, suffix = text[:i], strings.ToUpper(strings.TrimSpace(text[i:]))
			break
		}
	}
	n, err := strconv.ParseUint(digits, 10, 64)
	if err != nil {
		// An unexpected spelling is passed through rather than dropped: the operator
		// can still read the kernel's own string.
		return text
	}
	switch suffix {
	case "", "B":
		return humanBytes(n)
	case "K", "KB", "KIB":
		if bytes := n * 1024; bytes >= 1024*1024 {
			return fmt.Sprintf("%gM", float64(bytes)/(1024*1024))
		}
		return fmt.Sprintf("%dK", n)
	default:
		return text
	}
}

// humanDuration renders an uptime the way a person reads it.
func humanDuration(d time.Duration) string {
	if d <= 0 {
		return ""
	}
	days := int(d / (24 * time.Hour))
	hours := int(d/time.Hour) % 24
	mins := int(d/time.Minute) % 60
	switch {
	case days > 0:
		return fmt.Sprintf("%d 天 %d 小时 %d 分", days, hours, mins)
	case hours > 0:
		return fmt.Sprintf("%d 小时 %d 分", hours, mins)
	default:
		return fmt.Sprintf("%d 分", mins)
	}
}

// percentUsed is the share of a filesystem that is in use, clamped to 0..100 so a
// filesystem reporting odd numbers cannot print nonsense.
func percentUsed(total, available uint64) int {
	if total == 0 || available >= total {
		return 0
	}
	return int((total - available) * 100 / total)
}

// firstField returns the first value present among keys, for /proc files whose key
// names differ between architectures ("model name" on x86, "Hardware" on older ARM
// kernels, "cpu model" on some MIPS ones).
func firstField(record map[string]string, keys ...string) string {
	for _, k := range keys {
		if v := strings.TrimSpace(record[k]); v != "" {
			return v
		}
	}
	return ""
}

// hasToken reports whether a space separated list carries an exact token. The
// virtualization detection reads the hypervisor CPU flag this way, so a flag whose name
// merely contains "hypervisor" is not mistaken for it.
func hasToken(list, token string) bool {
	for _, f := range strings.Fields(list) {
		if f == token {
			return true
		}
	}
	return false
}

// parseKeyValue reads the "Key=Value" lines of a systemd tool's output.
func parseKeyValue(text string) map[string]string {
	out := map[string]string{}
	for _, line := range strings.Split(text, "\n") {
		k, v, ok := strings.Cut(strings.TrimSpace(line), "=")
		if !ok {
			continue
		}
		if k = strings.TrimSpace(k); k != "" {
			out[k] = strings.TrimSpace(v)
		}
	}
	return out
}
