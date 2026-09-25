// Package sbcore is the sing-box core this panel is built with: the node runs inside
// this binary instead of a separate `sing-box` executable, the way the panel is
// compiled with the library rather than shipped beside a downloaded core.
//
// The version is the sing-box module version pinned in go.mod, injected into
// github.com/sagernet/sing-box/constant at build time; the feature set comes from the
// build tags the release workflow passes (see docs/core-builds.md). Nothing here
// touches internal/*, so packages that only need to name the core (sysinfo) can import
// it without a cycle.
package sbcore

import (
	"context"
	"encoding/base64"
	"os"
	"runtime/debug"
	"strings"

	box "github.com/sagernet/sing-box"
	C "github.com/sagernet/sing-box/constant"
	"github.com/sagernet/sing-box/include"
	"github.com/sagernet/sing-box/option"
	"github.com/sagernet/sing/common/json"
	"github.com/sagernet/sing/service"
	"golang.zx2c4.com/wireguard/wgctrl/wgtypes"
)

// Version is the sing-box version compiled into this binary: the release build injects it
// from the go.mod requirement (-X .../constant.Version=1.14.2), and a plain `go build`
// falls back to the module version compile-time information carries.
func Version() string {
	if C.Version != "" && C.Version != "unknown" {
		return C.Version
	}
	if info, ok := debug.ReadBuildInfo(); ok {
		for _, dep := range info.Deps {
			if dep.Path == "github.com/sagernet/sing-box" {
				return strings.TrimPrefix(dep.Version, "v")
			}
		}
	}
	return C.Version
}

// configContext carries the protocol registries every config decode needs. include
// registers what the build tags enabled; a config naming something this build does not
// carry is rejected by the decode itself.
func configContext() context.Context {
	return include.Context(context.Background())
}

// loadOptions reads and decodes one server config.
func loadOptions(ctx context.Context, path string) (option.Options, error) {
	content, err := os.ReadFile(path)
	if err != nil {
		return option.Options{}, err
	}
	return json.UnmarshalExtendedContext[option.Options](ctx, content)
}

// Check reports whether this build accepts the config at path. It is the `sing-box
// check` the panel validates with: the instance is built and closed again without
// starting anything, so a config naming an API or a protocol the binary does not carry
// — or carrying an option this version no longer knows — fails here rather than at
// service start.
func Check(path string) error {
	ctx, cancel := context.WithCancel(service.ExtendContext(configContext()))
	defer cancel()
	options, err := loadOptions(ctx, path)
	if err != nil {
		return err
	}
	instance, err := box.New(box.Options{
		Context: ctx,
		Options: options,
	})
	if err != nil {
		return err
	}
	return instance.Close()
}

// Run starts the node at path and blocks until ctx is cancelled, then closes it. It is
// the `sing-box run -c` the sing-box service unit now executes as `easysb core run`.
func Run(ctx context.Context, path string) error {
	ctx, cancel := context.WithCancel(service.ExtendContext(configContext()))
	defer cancel()
	options, err := loadOptions(ctx, path)
	if err != nil {
		return err
	}
	instance, err := box.New(box.Options{
		Context: ctx,
		Options: options,
	})
	if err != nil {
		return err
	}
	if err := instance.Start(); err != nil {
		_ = instance.Close()
		return err
	}
	<-ctx.Done()
	return instance.Close()
}

// RealityKeypair generates a Reality key pair, encoded the way sing-box prints
// `generate reality-keypair`: raw URL-safe base64 of the X25519 private key and its
// public key. The panel stores the private half for the server and hands the public
// half to clients, so the encoding has to stay byte-for-byte what clients expect.
func RealityKeypair() (string, string, error) {
	privateKey, err := wgtypes.GeneratePrivateKey()
	if err != nil {
		return "", "", err
	}
	publicKey := privateKey.PublicKey()
	return base64.RawURLEncoding.EncodeToString(privateKey[:]),
		base64.RawURLEncoding.EncodeToString(publicKey[:]), nil
}
