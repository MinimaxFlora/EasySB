package tui

import (
	"charm.land/bubbletea/v2"

	"github.com/MinimaxFlora/EasySB/internal/i18n"
	"github.com/MinimaxFlora/EasySB/internal/icons"
)

type actionFunc func(a *App) tea.Cmd

type node struct {
	id     string
	label  func(i18n.Lang) string
	desc   func(i18n.Lang) string
	icon   func(icons.Set) string
	sub    *menu
	action actionFunc
}

type menu struct {
	id    string
	title func(i18n.Lang) string
	nodes []*node
}

func tk(key string) func(i18n.Lang) string {
	return func(l i18n.Lang) string { return l.T(key) }
}

func leaf(id, labelKey, descKey string, fn actionFunc) *node {
	return &node{id: id, label: tk(labelKey), desc: tk(descKey), action: fn}
}

func iconLeaf(id, labelKey, descKey string, ic func(icons.Set) string, fn actionFunc) *node {
	n := leaf(id, labelKey, descKey, fn)
	n.icon = ic
	return n
}

func stub(messageKey string) actionFunc {
	return func(a *App) tea.Cmd {
		a.setToast(a.lang.T(messageKey)+" · "+a.lang.T("action_todo"), true)
		return nil
	}
}

func buildRoot() *menu {
	return &menu{
		id:    "root",
		title: tk("menu_main"),
		nodes: []*node{
			{id: "kernel", label: tk("kernel_title"), desc: tk("menu_kernel"), icon: func(s icons.Set) string { return s.Core }, sub: buildKernel()},
			{id: "node", label: tk("node_title"), desc: tk("menu_node"), icon: func(s icons.Set) string { return s.Rocket }, sub: buildNode()},
			{id: "domain", label: tk("domain_title"), desc: tk("menu_domain"), icon: func(s icons.Set) string { return s.Globe }, sub: buildDomain()},
			{id: "subscribe", label: tk("sub_title"), desc: tk("menu_subscribe"), icon: func(s icons.Set) string { return s.Link }, sub: buildSubscribe()},
			{id: "service", label: tk("svc_title"), desc: tk("menu_service"), icon: func(s icons.Set) string { return s.Service }, sub: buildService()},
			iconLeaf("script-update", "menu_script_update", "script_update", func(s icons.Set) string { return s.Refresh }, stub("script_update")),
			iconLeaf("uninstall", "menu_uninstall", "uninstall_title", func(s icons.Set) string { return s.Trash }, stub("uninstall_title")),
		},
	}
}

func buildKernel() *menu {
	return &menu{
		id:    "kernel",
		title: tk("kernel_title"),
		nodes: []*node{
			leaf("kernel-stable", "kernel_stable", "kernel_source", kernelAction("stable")),
			leaf("kernel-alpha", "kernel_alpha", "kernel_source", kernelAction("alpha")),
			leaf("kernel-update", "kernel_update", "kernel_source", kernelAction("current")),
		},
	}
}

func buildNode() *menu {
	return &menu{
		id:    "node",
		title: tk("node_title"),
		nodes: []*node{
			iconLeaf("node-deploy", "node_deploy", "node_deploying", func(s icons.Set) string { return s.Rocket }, stub("node_deploying")),
			iconLeaf("node-params", "node_params", "param_ports", func(s icons.Set) string { return s.Tool }, func(a *App) tea.Cmd {
				a.push(buildParams())
				return nil
			}),
		},
	}
}

func buildParams() *menu {
	return &menu{
		id:    "params",
		title: tk("node_params"),
		nodes: []*node{
			leaf("param-uuid", "param_uuid", "param_uuid_prompt", stub("param_uuid")),
			leaf("param-password", "param_password", "param_pw_prompt", stub("param_password")),
			leaf("param-hop", "param_hop", "param_hop_prompt", stub("param_hop")),
			{id: "param-ports", label: tk("param_ports"), desc: tk("param_port_prompt"), sub: buildPorts()},
			{id: "param-sni", label: tk("param_sni"), desc: tk("param_sni_preset"), sub: buildSNI()},
			leaf("param-privkey", "param_privkey", "param_install_core_first", stub("param_privkey")),
			leaf("param-shortid", "param_shortid", "param_regen_shortid", stub("param_shortid")),
		},
	}
}

func buildPorts() *menu {
	ports := []struct{ proto, label string }{
		{"anytls", "AnyTLS"},
		{"hysteria2", "Hysteria2"},
		{"tuic", "TUIC v5"},
		{"vless-reality", "VLESS-Vision-Reality"},
		{"vmess-ws-tls", "VMess-WebSocket-TLS"},
	}
	nodes := make([]*node, 0, len(ports))
	for _, p := range ports {
		p := p
		nodes = append(nodes, &node{
			id:    "port-" + p.proto,
			label: func(i18n.Lang) string { return p.label },
			desc:  tk("param_port_prompt"),
			action: func(a *App) tea.Cmd {
				a.setToast(a.lang.T("param_ports")+" · "+p.label+" · "+a.lang.T("action_todo"), true)
				return nil
			},
		})
	}
	return &menu{id: "ports", title: tk("param_ports"), nodes: nodes}
}

func buildSNI() *menu {
	presets := []string{"academy.nvidia.com", "apple.com", "bing.com", "microsoft.com", "cloudflare.com"}
	nodes := make([]*node, 0, len(presets)+1)
	for _, preset := range presets {
		preset := preset
		nodes = append(nodes, &node{
			id:    "sni-" + preset,
			label: func(i18n.Lang) string { return preset },
			desc:  tk("param_sni_preset"),
			action: func(a *App) tea.Cmd {
				a.setToast(a.lang.T("param_sni")+" = "+preset+" · "+a.lang.T("action_todo"), true)
				return nil
			},
		})
	}
	nodes = append(nodes, leaf("sni-custom", "param_sni_custom", "param_sni_prompt", stub("param_sni")))
	return &menu{id: "sni", title: tk("param_sni"), nodes: nodes}
}

func buildDomain() *menu {
	return &menu{
		id:    "domain",
		title: tk("domain_title"),
		nodes: []*node{
			leaf("domain-issue", "domain_issue", "domain_prompt", stub("domain_installing_acme")),
			leaf("domain-list", "domain_list", "domain_empty", stub("domain_list")),
			leaf("domain-switch", "domain_switch", "domain_select", stub("domain_switch")),
			leaf("domain-remove", "domain_remove", "domain_remove_confirm", stub("domain_remove")),
		},
	}
}

func buildSubscribe() *menu {
	return &menu{
		id:    "subscribe",
		title: tk("sub_title"),
		nodes: []*node{
			leaf("sub-regen", "sub_regen", "sub_generated", stub("sub_regen")),
			leaf("sub-url", "sub_url", "sub_need_domain", showSubscriptionURL()),
			leaf("sub-qr", "sub_qr", "sub_no_qrencode", showSubscriptionQR()),
			leaf("sub-links", "sub_links", "sub_need_deploy", showShareLinks()),
		},
	}
}

func buildService() *menu {
	return &menu{
		id:    "service",
		title: tk("svc_title"),
		nodes: []*node{
			leaf("svc-start", "svc_start", "svc_running", serviceAction("start")),
			leaf("svc-stop", "svc_stop", "svc_stopped", serviceAction("stop")),
			leaf("svc-restart", "svc_restart", "svc_running", serviceAction("restart")),
			leaf("svc-status", "svc_status", "svc_title", serviceAction("status")),
			leaf("svc-enable", "svc_enable", "svc_enabled", serviceAction("enable")),
			leaf("svc-disable", "svc_disable", "svc_disabled", serviceAction("disable")),
		},
	}
}
