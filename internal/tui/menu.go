package tui

import (
	"charm.land/bubbletea/v2"

	"github.com/MinimaxFlora/EasySB/internal/i18n"
	"github.com/MinimaxFlora/EasySB/internal/icons"
	"github.com/MinimaxFlora/EasySB/internal/state"
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
			iconLeaf("script-update", "menu_script_update", "menu_script_update_desc", func(s icons.Set) string { return s.Refresh }, scriptUpdate()),
			iconLeaf("uninstall", "menu_uninstall", "menu_uninstall_desc", func(s icons.Set) string { return s.Trash }, uninstallAction()),
		},
	}
}

func buildKernel() *menu {
	return &menu{
		id:    "kernel",
		title: tk("kernel_title"),
		nodes: []*node{
			leaf("kernel-install-stable", "kernel_install_stable", "kernel_source", kernelAction("install-stable")),
			leaf("kernel-install-alpha", "kernel_install_alpha", "kernel_source", kernelAction("install-alpha")),
			leaf("kernel-switch", "kernel_switch", "kernel_switch_hint", kernelAction("switch")),
			leaf("kernel-update", "kernel_update", "kernel_source", kernelAction("update")),
		},
	}
}

func buildNode() *menu {
	return &menu{
		id:    "node",
		title: tk("node_title"),
		nodes: []*node{
			iconLeaf("node-deploy", "node_deploy", "node_deploying", func(s icons.Set) string { return s.Rocket }, deployNode()),
			{id: "node-protocols", label: tk("node_protocols"), desc: tk("node_select_protos"), icon: func(s icons.Set) string { return s.Service }, sub: buildProtocols()},
			iconLeaf("node-params", "node_params", "param_ports", func(s icons.Set) string { return s.Tool }, func(a *App) tea.Cmd {
				a.push(buildParams())
				return nil
			}),
		},
	}
}

// buildProtocols renders the protocol enable/disable list. Labels read the live
// state so the checkbox reflects the latest toggle.
func buildProtocols() *menu {
	nodes := make([]*node, 0, len(state.Keys))
	for _, key := range state.Keys {
		key := key
		nodes = append(nodes, &node{
			id: "proto-" + key,
			label: func(i18n.Lang) string {
				mark := "[ ]"
				if state.Load().Enabled[key] {
					mark = "[x]"
				}
				return mark + " " + state.Labels[key]
			},
			desc:   tk("node_select_protos"),
			action: toggleProtocol(key),
		})
	}
	return &menu{id: "protocols", title: tk("node_protocols"), nodes: nodes}
}

func buildParams() *menu {
	return &menu{
		id:    "params",
		title: tk("node_params"),
		nodes: []*node{
			leaf("param-uuid", "param_uuid", "param_uuid_prompt", editUUID()),
			leaf("param-password", "param_password", "param_pw_prompt", editPassword()),
			leaf("param-hop", "param_hop", "param_hop_prompt", editHop()),
			{id: "param-ports", label: tk("param_ports"), desc: tk("param_port_prompt"), sub: buildPorts()},
			{id: "param-sni", label: tk("param_sni"), desc: tk("param_sni_preset"), sub: buildSNI()},
			leaf("param-privkey", "param_privkey", "param_install_core_first", regenRealityKeys()),
			leaf("param-shortid", "param_shortid", "param_regen_shortid", regenShortID()),
		},
	}
}

func buildPorts() *menu {
	nodes := make([]*node, 0, len(state.Keys))
	for _, key := range state.Keys {
		key := key
		nodes = append(nodes, &node{
			id: "port-" + key,
			label: func(i18n.Lang) string {
				port := state.Load().Ports[key]
				return state.Labels[key] + " : " + port
			},
			desc:   tk("param_port_prompt"),
			action: editPort(key),
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
			id:     "sni-" + preset,
			label:  func(i18n.Lang) string { return preset },
			desc:   tk("param_sni_preset"),
			action: setSNI(preset),
		})
	}
	nodes = append(nodes, leaf("sni-custom", "param_sni_custom", "param_sni_prompt", editSNI()))
	return &menu{id: "sni", title: tk("param_sni"), nodes: nodes}
}

func buildDomain() *menu {
	return &menu{
		id:    "domain",
		title: tk("domain_title"),
		nodes: []*node{
			leaf("domain-issue", "domain_issue", "domain_prompt", issueCertAction()),
			leaf("domain-list", "domain_list", "domain_empty", listCerts()),
			leaf("domain-switch", "domain_switch", "domain_select", switchCertAction()),
			leaf("domain-remove", "domain_remove", "domain_remove_confirm", removeCertAction()),
		},
	}
}

func buildSubscribe() *menu {
	return &menu{
		id:    "subscribe",
		title: tk("sub_title"),
		nodes: []*node{
			leaf("sub-regen", "sub_regen", "sub_generated", regenerateSubscription()),
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
			leaf("svc-fw-apply", "fw_apply", "fw_added", firewallApply()),
			leaf("svc-fw-remove", "fw_remove", "fw_removed", firewallRemove()),
		},
	}
}
