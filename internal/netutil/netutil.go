// Package netutil provides small network helpers used during deployment.
package netutil

import (
	"context"
	"errors"
	"io"
	"net/http"
	"regexp"
	"strings"
	"time"
)

var endpoints = []string{
	"https://api.ip.sb/ip",
	"https://ifconfig.me/ip",
	"https://ipinfo.io/ip",
}

var ipRe = regexp.MustCompile(`^[0-9a-fA-F:.]+$`)

// PublicIP detects the host's public IP address, trying a few well-known
// endpoints in order.
func PublicIP(ctx context.Context) (string, error) {
	var lastErr error
	for _, url := range endpoints {
		ip, err := fetchIP(ctx, url)
		if err == nil && ip != "" {
			return ip, nil
		}
		if err != nil {
			lastErr = err
		}
	}
	if lastErr == nil {
		lastErr = errors.New("public IP detection failed")
	}
	return "", lastErr
}

func fetchIP(ctx context.Context, url string) (string, error) {
	cctx, cancel := context.WithTimeout(ctx, 8*time.Second)
	defer cancel()
	req, err := http.NewRequestWithContext(cctx, http.MethodGet, url, nil)
	if err != nil {
		return "", err
	}
	req.Header.Set("User-Agent", "EasySB")
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		return "", err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return "", errors.New(resp.Status)
	}
	body, err := io.ReadAll(io.LimitReader(resp.Body, 128))
	if err != nil {
		return "", err
	}
	ip := strings.TrimSpace(string(body))
	if !ipRe.MatchString(ip) {
		return "", errors.New("unexpected response")
	}
	return ip, nil
}
