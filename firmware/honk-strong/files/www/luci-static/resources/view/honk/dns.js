// SPDX-License-Identifier: GPL-3.0-only
// mosdns-style DNS split routing panel for honk.

'use strict';
'require rpc';
'require view';
'require ui';
'require view.honk.rpc as honk';

// NOTE: params MUST be an object map (not an array). LuCI's rpc.declare treats
// an array as positional args; passing a single object then drops all keys and
// the backend sees empty values (the "source_required" class of bug).
const callGet     = rpc.declare({ object: 'honk-dns', method: 'get_settings' });
const callSet     = rpc.declare({ object: 'honk-dns', method: 'set_settings',
	params: {
		enabled: 'enabled', redirect: 'redirect', local_dns: 'local_dns',
		remote_dns: 'remote_dns', stream_dns: 'stream_dns', bootstrap: 'bootstrap',
		fallback: 'fallback', apple_optimization: 'apple_optimization',
		dns_leak: 'dns_leak', cache: 'cache', cache_size: 'cache_size',
		lazy_cache_ttl: 'lazy_cache_ttl', reject_type65: 'reject_type65', ipv6: 'ipv6'
	}, expect: { '': {} } });
const callSetList = rpc.declare({ object: 'honk-dns', method: 'set_list',
	params: { name: 'name', content: 'content' }, expect: { '': {} } });
const callApply    = rpc.declare({ object: 'honk-dns', method: 'apply', expect: { '': {} } });
const callStatus   = rpc.declare({ object: 'honk-dns', method: 'status' });
const callPreview  = rpc.declare({ object: 'honk-dns', method: 'preview' });
const callRollback = rpc.declare({ object: 'honk-dns', method: 'rollback', expect: { '': {} } });

const SWITCHES = [ 'enabled', 'redirect', 'apple_optimization', 'dns_leak', 'cache', 'reject_type65', 'ipv6' ];

const LISTS = [
	{ key: 'whitelist',    title: '白名单（始终用国内 DNS）',  help: '加入的域名始终使用国内 DNS 解析，优先级最高。每行一个域名。', action: '→ 国内 DNS' },
	{ key: 'blacklist',    title: '黑名单（屏蔽解析）',        help: '加入的域名将屏蔽 DNS 解析。每行一个域名。',              action: '→ 拦截' },
	{ key: 'greylist',     title: '灰名单（始终用远程 DNS）',  help: '加入的域名始终使用远程 DNS 解析。每行一个域名。',      action: '→ 远程 DNS' },
	{ key: 'stream_media', title: '流媒体域名',                help: '使用流媒体 DNS 解析（需先在“基本设置”里填写流媒体 DNS）。每行一个域名。', action: '→ 流媒体 DNS' },
	{ key: 'ddns',         title: 'DDNS 域名',                 help: '加入的域名使用国内 DNS 解析。honk 的 TTL 由全局策略决定，无法按域名强制短 TTL。每行一个域名。', action: '→ 国内 DNS' },
	{ key: 'hosts',        title: 'Hosts 自定义',              help: 'honk 不支持按域名重写 A 记录；此处域名按“国内 DNS 解析”处理。每行一个域名。', action: '→ 国内 DNS' },
	{ key: 'redirect_list', title: '重定向域名',               help: 'honk 不支持域名到域名的 DNS 重定向；此处域名按“国内 DNS 解析”处理。每行一个域名。', action: '→ 国内 DNS' },
	{ key: 'ptr_blacklist',title: 'PTR 黑名单',                help: '加入的域名将阻止 PTR 反向解析。每行一个域名。',          action: '→ 拦截' }
];

const DNS_PRESETS = {
	local_dns: [
		[ 'https://223.5.5.5/dns-query', '阿里 DoH（223.5.5.5）' ],
		[ 'https://doh.pub/dns-query', '腾讯 DoH（doh.pub）' ],
		[ 'https://dns.alidns.com/dns-query', '阿里 DoH（alidns）' ],
		[ '119.29.29.29:53', '腾讯 UDP（119.29.29.29）' ],
		[ '223.5.5.5:53', '阿里 UDP（223.5.5.5）' ]
	],
	remote_dns: [
		[ 'https://8.8.8.8/dns-query', 'Google DoH（8.8.8.8）' ],
		[ 'https://1.1.1.1/dns-query', 'Cloudflare DoH（1.1.1.1）' ],
		[ 'tls://8.8.8.8', 'Google DoT（8.8.8.8）' ],
		[ 'tls://1.1.1.1', 'Cloudflare DoT（1.1.1.1）' ]
	]
};

let reloadTimer = null;
function scheduleReload() {
	if (reloadTimer) clearTimeout(reloadTimer);
	reloadTimer = setTimeout(function() { window.location.reload(); }, 800);
}
function flash(msg, ok) {
	const node = E('p', (ok !== false) ? {} : { 'class': 'alert-message' }, String(msg));
	// This LuCI build's addNotification(title, children, ...classes) has NO
	// timeout arg; passing one renders it as text (the stray "8000" bug).
	// Use addTimeLimitedNotification(title, children, timeout) when available.
	if (typeof ui.addTimeLimitedNotification === 'function')
		ui.addTimeLimitedNotification(null, node, 8000);
	else
		ui.addNotification(null, node);
}
function bool(v) { return v === true || v === 1 || v === '1' || v === 'true'; }

function field(label, control, help) {
	const cell = E('div', { 'class': 'cbi-value-field' }, [ control ]);
	if (help) cell.appendChild(E('div', { 'class': 'cbi-value-description honk-note' }, help));
	return E('div', { 'class': 'cbi-value' }, [
		E('label', { 'class': 'cbi-value-title' }, label), cell
	]);
}
function select(id, options) {
	const s = E('select', { 'class': 'cbi-input-select', 'id': id });
	options.forEach(function(o) { s.appendChild(E('option', { 'value': o[0] }, o[1])); });
	return s;
}
function checkbox(id) { return E('input', { 'type': 'checkbox', 'id': id }); }

// DNS server field: a preset select + a text input that always shows the real value.
function dnsServerField(labelText, key, current, presets, help) {
	const input = E('input', { 'class': 'cbi-input-text', 'id': 'dns-' + key, 'value': current || '' });
	const sel = E('select', { 'class': 'cbi-input-select', 'id': 'dns-preset-' + key });
	sel.appendChild(E('option', { 'value': '' }, '— 预设 —'));
	presets.forEach(function(p) { sel.appendChild(E('option', { 'value': p[0] }, p[1])); });
	sel.appendChild(E('option', { 'value': '__custom' }, '自定义'));
	sel.addEventListener('change', function() {
		if (sel.value && sel.value !== '__custom') input.value = sel.value;
	});
	const wrap = E('div', {}, [ sel, E('div', { 'style': 'height:4px' }), input ]);
	return { row: field(labelText, wrap, help), input: input };
}

return view.extend({
	handleSave: null,
	handleSaveApply: null,
	handleReset: null,

	load: function() {
		return Promise.all([
			callGet().catch(function(e) { return { error: e.message || String(e) }; }),
			callStatus().catch(function(e) { return {}; })
		]).then(function(r) { return { cfg: r[0] || {}, status: r[1] || {} }; });
	},

	render: function(data) {
		honk.installStyles();
		// self-contained tab styles (do not touch the shared honk.css)
		if (!document.getElementById('honk-dns-tab-styles')) {
			const st = document.createElement('style');
			st.id = 'honk-dns-tab-styles';
			st.textContent = '.honk-tabs{display:flex;gap:6px;margin:6px 0 12px;border-bottom:1px solid #ccc;padding-bottom:6px}' +
				'.honk-tab-btn{border-radius:4px 4px 0 0}' +
				'.honk-tab-active{background:#37c #0a7 !important;color:#fff !important;font-weight:bold}' +
				'.honk-tab-pane{margin-top:4px}';
			document.head.appendChild(st);
		}
		const cfg = data.cfg || {};
		const status = data.status || {};
		const page = E('div', { 'class': 'cbi-map honk-page' });

		if (cfg.error)
			page.appendChild(E('div', { 'class': 'alert-message' }, _('读取 DNS 设置失败：%s').format(cfg.error)));

		// ---- header: status + global actions ----
		const top = E('div', { 'class': 'honk-card' });
		top.appendChild(E('h3', { 'class': 'honk-card-title' }, _('DNS 分流（mosdns 风格）')));
		top.appendChild(E('p', { 'class': 'honk-status-msg' },
			_('引擎：%s · 已应用规则：%d 条')
				.format(bool(status.running) ? _('运行中') : _('honk 未运行'), Number(status.applied_rules || 0))));
		top.appendChild(E('p', { 'class': 'honk-note' },
			_('国内域名走国内 DNS，国外域名走远程 DNS；白名单/黑名单/灰名单优先级最高。修改后点“保存并应用”才会写入 honk 配置并生效。')));
		top.appendChild(E('p', { 'class': 'honk-note' },
			_('安全说明：只改写带 HONK-DNS 标记的配置块，您现有的路由规则不会被覆盖；应用前自动校验语法并备份，可一键回滚。')));

		const saveApplyBtn = E('button', { 'class': 'cbi-button cbi-button-positive' }, _('保存并应用'));
		const previewBtn = E('button', { 'class': 'cbi-button' }, _('预览生成的规则'));
		const rbBtn = E('button', { 'class': 'cbi-button cbi-button-remove' }, _('回滚'));
		const topMsg = E('span', { 'class': 'honk-note' }, '');

		// Collect current state from all controls, then persist + apply.
		function collectSettings() {
			const out = {};
			SWITCHES.forEach(function(k) {
				const el = document.getElementById('dns-' + k);
				out[k] = el ? el.checked : false;
			});
			out.local_dns   = document.getElementById('dns-local_dns').value.trim();
			out.remote_dns  = document.getElementById('dns-remote_dns').value.trim();
			out.stream_dns  = document.getElementById('dns-stream_dns').value.trim();
			out.bootstrap   = document.getElementById('dns-bootstrap').value.trim();
			out.fallback    = document.getElementById('dns-fallback').value;
			out.cache_size  = parseInt(document.getElementById('dns-cache_size').value, 10) || 8000;
			out.lazy_cache_ttl = parseInt(document.getElementById('dns-lazy_cache_ttl').value, 10) || 86400;
			return out;
		}
		function collectLists() {
			const out = [];
			LISTS.forEach(function(l) {
				const el = document.getElementById('dns-list-' + l.key);
				out.push({ name: l.key, content: el ? el.value : '' });
			});
			return out;
		}
		function saveAll(doApply) {
			const lists = collectLists();
			saveApplyBtn.disabled = true;
			return callSet(collectSettings()).then(function(res) {
				if (res && res.ok === false) throw new Error(res.message || _('保存基本设置失败'));
				let chain = Promise.resolve();
				lists.forEach(function(item) {
					chain = chain.then(function() {
						return callSetList({ name: item.name, content: item.content }).then(function(r) {
							if (r && r.ok === false) throw new Error(r.message || (_('保存清单失败：%s').format(item.name)));
						});
					});
				});
				return chain;
			}).then(function() {
				if (!doApply) return null;
				return callApply().then(function(res) {
					if (res && res.ok === false) throw new Error(res.message || _('应用失败'));
					return res;
				});
			}).then(function(res) {
				saveApplyBtn.disabled = false;
				topMsg.textContent = doApply ? _('已保存并应用：%s').format((res && res.message) || 'ok') : _('已保存');
				if (doApply) scheduleReload();
			}).catch(function(e) {
				saveApplyBtn.disabled = false;
				topMsg.textContent = _('错误：%s').format(e.message || String(e));
				flash(e.message || String(e), false);
			});
		}

		saveApplyBtn.addEventListener('click', function() { saveAll(true); });
		previewBtn.addEventListener('click', function() {
			return callPreview().then(function(res) { window.alert(res.preview || '(empty)'); })
				.catch(function(e) { flash(e.message || String(e), false); });
		});
		rbBtn.addEventListener('click', function() {
			if (!confirm(_('确定回滚 DNS 分流配置到上一次备份吗？'))) return;
			return callRollback().then(function(res) {
				flash(_('回滚结果：%s').format(res.message || 'ok'), res.ok !== false);
				if (res.ok !== false) scheduleReload();
			}).catch(function(e) { flash(e.message || String(e), false); });
		});
		top.appendChild(E('div', { 'class': 'cbi-page-actions' }, [ saveApplyBtn, previewBtn, rbBtn, topMsg ]));
		page.appendChild(top);

		// ---- tabs ----
		const tabBar = E('div', { 'class': 'honk-tabs' });
		const btnBasic = E('button', { 'class': 'cbi-button honk-tab-btn' }, _('基本设置'));
		const btnRules = E('button', { 'class': 'cbi-button honk-tab-btn' }, _('规则列表'));
		const paneBasic = E('div', { 'class': 'honk-tab-pane' });
		const paneRules = E('div', { 'class': 'honk-tab-pane', 'style': 'display:none' });
		function activate(which) {
			paneBasic.style.display = (which === 'basic') ? '' : 'none';
			paneRules.style.display = (which === 'rules') ? '' : 'none';
			btnBasic.className = 'cbi-button honk-tab-btn' + (which === 'basic' ? ' honk-tab-active' : '');
			btnRules.className = 'cbi-button honk-tab-btn' + (which === 'rules' ? ' honk-tab-active' : '');
		}
		btnBasic.addEventListener('click', function() { activate('basic'); });
		btnRules.addEventListener('click', function() { activate('rules'); });
		tabBar.appendChild(btnBasic); tabBar.appendChild(btnRules);
		page.appendChild(tabBar);

		// ===== Tab 1: basic settings =====
		const basic = E('div', { 'class': 'honk-card' });
		basic.appendChild(E('h3', { 'class': 'honk-card-title' }, _('基本设置')));

		function sw(k, label, help) {
			const el = checkbox('dns-' + k); el.checked = bool(cfg[k]);
			return field(label, el, help);
		}

		basic.appendChild(sw('enabled', _('启用'), _('关闭后 DNS 分流规则不写入配置。')));
		basic.appendChild(sw('redirect', _('DNS 转发'), _('劫持局域网 DNS 请求到 honk（需 honk 接管 53 端口）。')));

		const localF = dnsServerField(_('国内 DNS 服务器'), 'local_dns', cfg.local_dns, DNS_PRESETS.local_dns,
			_('国内域名使用的 DNS。可选预设或填写自定义地址（DoH/DoT/UDP）。'));
		const remoteF = dnsServerField(_('远程 DNS 服务器'), 'remote_dns', cfg.remote_dns, DNS_PRESETS.remote_dns,
			_('国外域名使用的 DNS。建议加密协议（DoH/DoT）。'));
		basic.appendChild(localF.row);
		basic.appendChild(remoteF.row);
		basic.appendChild(field(_('流媒体 DNS 服务器'), E('input', {
			'class': 'cbi-input-text', 'id': 'dns-stream_dns', 'value': cfg.stream_dns || '',
			'placeholder': 'https://1.1.1.1/dns-query（留空则流媒体域名走远程 DNS）'
		}), _('流媒体域名专用 DNS，留空则不启用。')));
		basic.appendChild(field(_('Bootstrap DNS'), E('input', {
			'class': 'cbi-input-text', 'id': 'dns-bootstrap', 'value': cfg.bootstrap || '',
			'placeholder': '119.29.29.29:53'
		}), _('用于解析 DoH/DoT 服务器域名的明文 DNS。')));

		const fb = select('dns-fallback', [
			[ 'remote', _('远程 DNS（remote）') ],
			[ 'mos_local', _('国内 DNS（mos_local）') ],
			[ 'accept', _('接受（accept）') ],
			[ '', _('不设置') ]
		]);
		fb.value = cfg.fallback || 'remote';
		basic.appendChild(field(_('默认回退'), fb, _('未命中任何规则时使用的 DNS。')));

		basic.appendChild(sw('ipv6', _('允许 IPv6（AAAA）'), _('关闭时拦截 AAAA 查询，减少 IPv6 连接卡住。')));
		basic.appendChild(sw('reject_type65', _('拦截 HTTPS/SVCB（类型65）'), _('减少 Chrome 对 HTTPS 记录的额外查询。')));
		basic.appendChild(sw('apple_optimization', _('Apple 域名优化'), _('预留选项：honk 通过国内 DNS 解析 apple@cn 分类。')));
		basic.appendChild(sw('dns_leak', _('防止 DNS 泄露'), _('预留选项：honk 由 eBPF 劫持 53 端口，默认不走系统 DNS。')));

		basic.appendChild(sw('cache', _('启用 DNS 缓存'), _('honk 内置缓存；此项为预留开关。')));
		basic.appendChild(field(_('缓存大小'), E('input', {
			'class': 'cbi-input-text', 'id': 'dns-cache_size', 'type': 'number', 'value': cfg.cache_size || 8000
		}), _('预留选项（honk 缓存大小为全局值）。')));
		basic.appendChild(field(_('乐观缓存 TTL'), E('input', {
			'class': 'cbi-input-text', 'id': 'dns-lazy_cache_ttl', 'type': 'number', 'value': cfg.lazy_cache_ttl || 86400
		}), _('预留选项（honk 不支持按插件设置）。')));
		paneBasic.appendChild(basic);

		// ===== Tab 2: rule lists =====
		const rulesCard = E('div', { 'class': 'honk-card' });
		rulesCard.appendChild(E('h3', { 'class': 'honk-card-title' }, _('规则列表')));
		rulesCard.appendChild(E('p', { 'class': 'honk-note' },
			_('每行一个域名。支持前缀：domain:（后缀，默认）、full:（完整）、keyword:（关键词）、geosite:（如 geosite:cn）、以 . 开头表示后缀。# 开头为注释。')));
		LISTS.forEach(function(l) {
			const ta = E('textarea', {
				'id': 'dns-list-' + l.key, 'rows': '5',
				'placeholder': 'example.com\n.geosite 示例：geosite:cn\nfull:ads.example.com',
				'style': 'width:100%;font-family:monospace'
			});
			ta.value = cfg[l.key] || '';
			rulesCard.appendChild(field(l.title + '（' + l.action + '）', ta, l.help));
		});
		paneRules.appendChild(rulesCard);

		page.appendChild(paneBasic);
		page.appendChild(paneRules);
		activate('basic');

		return page;
	}
});
