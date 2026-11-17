// SPDX-License-Identifier: GPL-3.0-only

'use strict';
'require rpc';
'require view';
'require ui';
'require view.honk.rpc as honk';

const callList = rpc.declare({ object: 'honk-adblock', method: 'list', expect: { '': {} } });
const callStatus = rpc.declare({ object: 'honk-adblock', method: 'status', expect: { '': {} } });
const callAdd = rpc.declare({
	object: 'honk-adblock', method: 'add',
	params: { name: 'name', url: 'url', format: 'format', inline: 'inline', enabled: 'enabled' }, expect: { '': {} }
});
const callRemove = rpc.declare({
	object: 'honk-adblock', method: 'remove',
	params: { section: 'section', name: 'name' }, expect: { '': {} }
});
const callSet = rpc.declare({
	object: 'honk-adblock', method: 'set',
	params: { section: 'section', name: 'name', enabled: 'enabled' }, expect: { '': {} }
});
const callSetGlobal = rpc.declare({
	object: 'honk-adblock', method: 'set_global',
	params: { enabled: 'enabled' }, expect: { '': {} }
});
const callRefresh = rpc.declare({ object: 'honk-adblock', method: 'refresh', expect: { '': {} } });
const callApplyRule = rpc.declare({ object: 'honk-adblock', method: 'apply_rule', expect: { '': {} } });

const FORMATS = [
	[ 'auto', '自动识别' ],
	[ 'domain', '纯域名' ],
	[ 'hosts', 'Hosts / IP-域名' ],
	[ 'dnsmasq', 'dnsmasq server/address' ],
	[ 'adblock', 'Adblock Plus（||域名^）' ]
];

let reloadTimer = null;
function scheduleReload() {
	if (reloadTimer)
		clearTimeout(reloadTimer);
	reloadTimer = setTimeout(function() { window.location.reload(); }, 700);
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

function field(label, control, help) {
	const cell = E('div', { 'class': 'cbi-value-field' }, [ control ]);
	if (help)
		cell.appendChild(E('div', { 'class': 'cbi-value-description honk-note' }, help));
	return E('div', { 'class': 'cbi-value' }, [
		E('label', { 'class': 'cbi-value-title' }, label),
		cell
	]);
}

function isHttpUrl(value) {
	try {
		const u = new URL(value);
		return (u.protocol === 'http:' || u.protocol === 'https:') && !!u.hostname;
	}
	catch (e) { return false; }
}

return view.extend({
	handleSave: null,
	handleSaveApply: null,
	handleReset: null,

	load: function() {
		return Promise.all([
			callList().catch(function(e) { return { error: e.message || String(e), sources: [] }; }),
			callStatus().catch(function(e) { return { statusError: e.message || String(e) }; })
		]).then(function(r) {
			return { list: r[0] || {}, status: r[1] || {} };
		});
	},

	render: function(data) {
		honk.installStyles();
		const list = data.list || {};
		const status = data.status || {};
		const page = E('div', { 'class': 'cbi-map honk-page' });

		if (list.error)
			page.appendChild(E('div', { 'class': 'alert-message' }, _('无法读取广告拦截配置：%s').format(list.error)));

		// ---- 状态卡片 ----
		const statusCard = E('div', { 'class': 'honk-card' });
		statusCard.appendChild(E('h3', { 'class': 'honk-card-title' }, _('广告拦截状态')));
		const running = status.running === true;
		const domCount = Number(list.domains || 0);
		const bytes = Number(list.bytes || 0);
		statusCard.appendChild(E('p', { 'class': 'honk-status-msg' },
			_('引擎：%s · 规则：%d 个域名 · 规则包：%d 字节')
				.format(running ? _('运行中') : _('honk 未运行'), domCount, bytes)));
		if (!running)
			statusCard.appendChild(E('p', { 'class': 'honk-note' },
				_('honk 必须处于运行状态，规则才会生效。请在「概览」页面启动 honk。')));

		const refreshBtn = E('button', { 'class': 'cbi-button cbi-button-action' }, _('立即更新规则'));
		refreshBtn.addEventListener('click', function() {
			refreshBtn.disabled = true;
			return callRefresh().then(function(res) {
				flash(_('规则已更新：%s').format(res.message || 'ok'), res.ok !== false);
				refreshBtn.disabled = false;
				if (res.ok !== false) scheduleReload();
			}).catch(function(e) { refreshBtn.disabled = false; flash(e.message || String(e), false); });
		});
		const applyRuleBtn = E('button', { 'class': 'cbi-button cbi-button-positive' }, _('在 honk 中启用广告过滤'));
		applyRuleBtn.addEventListener('click', function() {
			applyRuleBtn.disabled = true;
			return callApplyRule().then(function(res) {
				flash(_('过滤规则：%s').format(res.message || 'ok'), res.ok !== false);
				applyRuleBtn.disabled = false;
			}).catch(function(e) { applyRuleBtn.disabled = false; flash(e.message || String(e), false); });
		});
		statusCard.appendChild(E('div', { 'class': 'cbi-page-actions' }, [ refreshBtn, applyRuleBtn ]));
		page.appendChild(statusCard);

		// ---- 订阅卡片 ----
		const subCard = E('div', { 'class': 'honk-card' });
		subCard.appendChild(E('h3', { 'class': 'honk-card-title' }, _('自定义广告订阅')));
		subCard.appendChild(E('p', { 'class': 'honk-note' },
			_('可添加任意广告拦截订阅地址，也可直接粘贴自己的规则。每个订阅源都能独立开启、关闭或删除。')));

		const listBox = E('div', { 'class': 'honk-subscription-list' });
		const sources = Array.isArray(list.sources) ? list.sources : [];
		if (!sources.length)
			listBox.appendChild(E('p', { 'class': 'honk-note' }, _('暂无订阅。')));

		sources.forEach(function(src) {
			const row = E('div', { 'class': 'cbi-value honk-sub-row' });
			const cb = E('input', { 'type': 'checkbox' });
			cb.checked = src.enabled === true;
			cb.addEventListener('change', function() {
				return callSet({ section: src.section, name: src.name, enabled: cb.checked })
					.then(function(res) {
						flash(_('%s 已%s').format(src.name, cb.checked ? _('启用') : _('停用')), res.ok !== false);
						return callRefresh();
					})
					.then(function() { scheduleReload(); })
					.catch(function(e) { flash(e.message || String(e), false); });
			});
			const label = E('div', { 'class': 'cbi-value-field' });
			label.appendChild(E('strong', {}, src.name || src.section));
			const desc = src.inline ? _('自定义规则') : (src.url || '');
			label.appendChild(E('div', { 'class': 'honk-note' }, desc));
			label.appendChild(E('div', { 'class': 'honk-note' }, _('格式：%s').format(src.format || 'auto')));
			const delBtn = E('button', { 'class': 'cbi-button cbi-button-remove' }, _('删除'));
			delBtn.addEventListener('click', function() {
				if (!confirm(_('确定删除订阅「%s」吗？').format(src.name || src.section)))
					return;
				return callRemove({ section: src.section, name: src.name }).then(function(res) {
					flash(_('已删除 %s').format(src.name), res.ok !== false);
					return callRefresh();
				}).then(function() { scheduleReload(); })
				  .catch(function(e) { flash(e.message || String(e), false); });
			});
			row.appendChild(E('label', { 'class': 'cbi-value-title' }, [ cb ]));
			row.appendChild(label);
			row.appendChild(delBtn);
			listBox.appendChild(row);
		});
		subCard.appendChild(listBox);
		page.appendChild(subCard);

		// ---- 添加卡片 ----
		const addCard = E('form', { 'class': 'honk-card' });
		addCard.appendChild(E('h3', { 'class': 'honk-card-title' }, _('添加订阅')));
		const nameInput = E('input', { 'class': 'cbi-input-text', 'id': 'ha-name', 'required': 'required' });
		const urlInput = E('input', { 'class': 'cbi-input-text', 'id': 'ha-url', 'type': 'url', 'placeholder': 'https://example.com/adblock.txt' });
		const inlineInput = E('textarea', { 'id': 'ha-inline', 'rows': '5', 'placeholder': '0.0.0.0 ads.example.com\n||tracker.example^\ndoubleclick.net' });
		const fmtSelect = E('select', { 'class': 'cbi-input-select', 'id': 'ha-format' });
		FORMATS.forEach(function(f) { fmtSelect.appendChild(E('option', { 'value': f[0] }, f[1])); });
		const addMsg = E('p', { 'class': 'honk-status-msg' }, '');
		const addBtn = E('button', { 'class': 'cbi-button cbi-button-positive', 'type': 'submit' }, _('添加并更新'));

		addCard.appendChild(field(_('名称'), nameInput));
		addCard.appendChild(field(_('订阅地址'), urlInput,
			_('留空则使用下方粘贴的自定义规则。')));
		addCard.appendChild(field(_('或自定义规则'), inlineInput,
			_('每行一个域名。支持 Hosts、dnsmasq、Adblock Plus 以及纯域名格式。')));
		addCard.appendChild(field(_('格式'), fmtSelect));
		addCard.appendChild(E('div', { 'class': 'cbi-page-actions' }, addBtn));
		addCard.appendChild(addMsg);

		addCard.addEventListener('submit', function(ev) {
			ev.preventDefault();
			const name = nameInput.value.trim();
			const url = urlInput.value.trim();
			const inline = inlineInput.value.trim();
			if (!name) { addMsg.textContent = _('请填写名称。'); return; }
			if (!url && !inline) { addMsg.textContent = _('请填写订阅地址或自定义规则。'); return; }
			if (url && !isHttpUrl(url) && url.charAt(0) !== '/') {
				addMsg.textContent = _('请填写有效的 HTTP(S) 地址或绝对路径。');
				return;
			}
			addBtn.disabled = true;
			callAdd({ name: name, url: url, format: fmtSelect.value, inline: inline, enabled: true })
				.then(function(res) {
					if (res.ok === false) { addMsg.textContent = res.message || _('添加失败'); addBtn.disabled = false; return null; }
					return callRefresh();
				})
				.then(function(res) {
					if (!res) return;
					flash(_('已添加 %s 并刷新规则。').format(name), true);
					scheduleReload();
				})
				.catch(function(e) { addMsg.textContent = e.message || String(e); addBtn.disabled = false; });
		});
		page.appendChild(addCard);

		return page;
	}
});
