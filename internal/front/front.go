// Package front is the camouflage site's face: one HTTPS listener on the
// operator's domain that serves the subscription endpoint under /sub/ and
// reverse-proxies everything else to the application the operator picked.
//
// The point is what a probe sees. A scanner that finds the domain, or a firewall
// that follows a legitimate handshake to it, gets an ordinary-looking site — a
// file list, a memo board, a dashboard — served over a certificate for that
// domain. The proxy ports are never named, and the subscription endpoint sits
// behind the same certificate rather than on a bare http:// address:port.
//
// Nothing here listens on a plaintext port. The panel deliberately does not run
// an HTTP listener for the site, because the whole deployment this serves is
// meant to look like a normal HTTPS site.
package front

import (
	"context"
	"crypto/tls"
	"errors"
	"fmt"
	"net"
	"net/http"
	"net/http/httputil"
	"net/url"
	"os"
	"strings"
	"sync"
	"time"
)

// SubPath is the prefix the subscription endpoint keeps under the domain. It has
// to match what the subscription service itself serves.
const SubPath = "/sub/"

// maxLogBytes is where the access log is compacted: past this size it is cut back
// to its last keepLogLines lines, so a probe storm cannot fill the disk.
const (
	maxLogBytes  = 512 << 10
	keepLogLines = 200
)

// Options describes the site being served.
type Options struct {
	// Listen is the address the front binds, ":443" for the endpoint the site is
	// meant to be reached at.
	Listen string
	// Domain is the name on the certificate, used for logs and for the session
	// Host check.
	Domain string
	// CertFile and KeyFile are the certificate and key to serve. The front has no
	// fallback certificate: without them it refuses to start, because a
	// self-signed site is worse than no site at all.
	CertFile string
	KeyFile  string
	// App is the application's display name, for logs.
	App string
	// AppTarget is the loopback address of the application, host:port.
	AppTarget string
	// Sub serves the subscription endpoint. When nil, /sub/ paths are proxied to
	// the application like everything else.
	Sub http.Handler
	// LogFile collects the access log, empty to keep no log.
	LogFile string
	// Log reports lifecycle lines (start, stop, errors) to the panel's own log.
	Log func(string)
}

// Handler builds the site: subscription paths to the subscription handler, the
// rest to the application.
func Handler(o Options) http.Handler {
	proxy := proxyTo(o.AppTarget, o.App, o.Log)
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		rec := &recorder{ResponseWriter: w, status: http.StatusOK}
		defer func() { appendLog(o.LogFile, accessLine(r, rec.status)) }()

		if o.Sub != nil && strings.HasPrefix(r.URL.Path, SubPath) {
			o.Sub.ServeHTTP(rec, r)
			return
		}
		proxy.ServeHTTP(rec, r)
	})
}

// proxyTo builds the reverse proxy in front of one application.
func proxyTo(target, app string, log func(string)) *httputil.ReverseProxy {
	if log == nil {
		log = func(string) {}
	}
	addr := target
	if !strings.Contains(addr, "://") {
		addr = "http://" + addr
	}
	upstream, err := url.Parse(addr)
	if err != nil {
		// A malformed target cannot be dialled; the handler still has to exist,
		// so point it at a dead loopback address and report every request.
		log("front: bad application address " + target + ": " + err.Error())
		upstream, _ = url.Parse("http://127.0.0.1:1")
	}

	proxy := httputil.NewSingleHostReverseProxy(upstream)
	proxy.ErrorHandler = func(w http.ResponseWriter, r *http.Request, err error) {
		log(fmt.Sprintf("front: %s unavailable: %v", app, err))
		http.Error(w, "502 Bad Gateway", http.StatusBadGateway)
	}
	return proxy
}

// Run serves the site until the context is cancelled. It reports why it stopped.
func Run(ctx context.Context, o Options) error {
	log := o.Log
	if log == nil {
		log = func(string) {}
	}
	if o.CertFile == "" || o.KeyFile == "" {
		return errors.New("front: no certificate for the domain yet")
	}
	loader, err := newCertLoader(o.CertFile, o.KeyFile)
	if err != nil {
		return err
	}

	listener, err := net.Listen("tcp", o.Listen)
	if err != nil {
		return fmt.Errorf("front: %w", err)
	}

	server := &http.Server{
		Handler:           Handler(o),
		ReadHeaderTimeout: 20 * time.Second,
		IdleTimeout:       2 * time.Minute,
		TLSConfig: &tls.Config{
			MinVersion:     tls.VersionTLS12,
			NextProtos:     []string{"h2", "http/1.1"},
			GetCertificate: loader.get,
		},
	}

	done := make(chan error, 1)
	go func() {
		err := server.ServeTLS(listener, "", "")
		if errors.Is(err, http.ErrServerClosed) {
			err = nil
		}
		done <- err
	}()
	log(fmt.Sprintf("front: %s serving https://%s -> %s (%s)", o.Listen, o.Domain, o.AppTarget, o.App))

	select {
	case <-ctx.Done():
		shutdown, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		_ = server.Shutdown(shutdown)
		return nil
	case err := <-done:
		return err
	}
}

// certLoader serves the certificate and picks up a renewed one without a restart:
// the renewal timer rewrites the file under the same name, and the next handshake
// reads it.
type certLoader struct {
	certFile string
	keyFile  string

	mu   sync.Mutex
	cert *tls.Certificate
	mod  time.Time
}

func newCertLoader(certFile, keyFile string) (*certLoader, error) {
	l := &certLoader{certFile: certFile, keyFile: keyFile}
	if _, err := l.get(nil); err != nil {
		return nil, err
	}
	return l, nil
}

func (l *certLoader) get(*tls.ClientHelloInfo) (*tls.Certificate, error) {
	l.mu.Lock()
	defer l.mu.Unlock()

	info, err := os.Stat(l.certFile)
	if err != nil {
		return nil, err
	}
	if l.cert != nil && info.ModTime().Equal(l.mod) {
		return l.cert, nil
	}
	cert, err := tls.LoadX509KeyPair(l.certFile, l.keyFile)
	if err != nil {
		return nil, err
	}
	l.cert, l.mod = &cert, info.ModTime()
	return l.cert, nil
}

// recorder remembers the status code for the access log.
type recorder struct {
	http.ResponseWriter
	status int
	wrote  bool
}

func (r *recorder) WriteHeader(code int) {
	if !r.wrote {
		r.status, r.wrote = code, true
	}
	r.ResponseWriter.WriteHeader(code)
}

func (r *recorder) Write(b []byte) (int, error) {
	r.wrote = true
	return r.ResponseWriter.Write(b)
}

// accessLine renders one request for the access log. It is the line an operator
// reads to tell a real visitor from a scanner.
func accessLine(r *http.Request, status int) string {
	host, _, err := net.SplitHostPort(r.RemoteAddr)
	if err != nil {
		host = r.RemoteAddr
	}
	ua := r.UserAgent()
	if len(ua) > 120 {
		ua = ua[:120]
	}
	return fmt.Sprintf("%s %s %s %s %s %d %q",
		time.Now().Format(time.RFC3339), host, r.Host, r.Method, r.URL.RequestURI(), status, ua)
}

// appendLog writes a line to the access log, compacting the file when it grows
// past maxLogBytes. Logging never fails a request.
func appendLog(file, line string) {
	if file == "" || line == "" {
		return
	}
	f, err := os.OpenFile(file, os.O_CREATE|os.O_APPEND|os.O_WRONLY, 0o644)
	if err != nil {
		return
	}
	if _, err := f.WriteString(line + "\n"); err != nil {
		f.Close()
		return
	}
	f.Close()

	// Compact after the write rather than before it, so the file cannot sit above
	// the limit for a whole line's worth of requests.
	if info, err := os.Stat(file); err == nil && info.Size() > maxLogBytes {
		compact(file)
	}
}

// compact cuts the access log back to its most recent lines.
func compact(file string) {
	body, err := os.ReadFile(file)
	if err != nil {
		return
	}
	lines := strings.Split(strings.TrimRight(string(body), "\n"), "\n")
	if len(lines) > keepLogLines {
		lines = lines[len(lines)-keepLogLines:]
	}
	_ = os.WriteFile(file, []byte(strings.Join(lines, "\n")+"\n"), 0o644)
}
