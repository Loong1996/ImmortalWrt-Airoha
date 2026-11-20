'require view';

// Lucky 自带完整的 Web 管理界面（默认 16601 端口），LuCI 这边只做一个入口页，
// 不重复实现配置表单 —— lucky 的配置项多且版本间会变，镜像一份反而容易和本体脱节。
return view.extend({
	load: function() {
		return Promise.resolve();
	},

	render: function() {
		var host = window.location.hostname;
		var url = 'http://' + host + ':16601/';

		return E('div', { 'class': 'cbi-map' }, [
			E('h2', {}, 'Lucky'),
			E('div', { 'class': 'cbi-map-descr' },
				'动态域名、端口转发、STUN 内网穿透、反向代理、Web 服务。' +
				'服务由 procd 托管（/etc/init.d/lucky），配置文件在 /etc/lucky/lucky.conf。'),

			E('div', { 'class': 'cbi-section' }, [
				E('p', {}, [
					E('a', {
						'href': url,
						'target': '_blank',
						'rel': 'noopener',
						'class': 'btn cbi-button cbi-button-action'
					}, '打开 Lucky 管理界面（' + url + '）')
				]),
				E('p', { 'class': 'cbi-section-descr' },
					'首次登录请用 lucky 官方的默认账号，进去后立刻改掉；' +
					'忘记密码可以停服务后删除 /etc/lucky/lucky.conf 重新初始化。')
			])
		]);
	},

	handleSave: null,
	handleSaveApply: null,
	handleReset: null
});
