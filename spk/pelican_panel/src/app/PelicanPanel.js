// Namespace definition
Ext.ns("PelicanPanel");

// Application definition
Ext.define("PelicanPanel.AppInstance", {
	extend: "SYNO.SDS.AppInstance",
	appWindowName: "PelicanPanel.AppWindow"
});

// Window definition with iframe to Pelican Panel
Ext.define("PelicanPanel.AppWindow", {
	extend: "SYNO.SDS.AppWindow",

	constructor: function(config) {
		this.appInstance = config.appInstance;

		// Build iframe URL - use CGI proxy for same-origin (avoids DSM CSP blocking)
		// panel.cgi proxies requests to loading-proxy.py on port 8080
		var iframeSrc = '/webman/3rdparty/pelican_panel/panel.cgi/';

		// Direct URL for "Open in new tab" button (bypasses DSM, opens in browser)
		// Note: May not work with QuickConnect (only DSM ports are tunneled)
		var host = window.location.hostname;
		var directUrl = 'http://' + host + ':8080/';

		// Create unique iframe ID
		var iframeId = 'pelican-panel-iframe-' + Ext.id();

		config = Ext.apply({
			// Window properties
			resizable: true,
			maximizable: true,
			minimizable: true,
			width: 1200,
			height: 800,
			minWidth: 800,
			minHeight: 600,

			// Layout
			layout: 'fit',

			// Iframe content
			items: [{
				xtype: 'box',
				autoEl: {
					tag: 'iframe',
					id: iframeId,
					name: iframeId,
					src: iframeSrc,
					width: '100%',
					height: '100%',
					frameborder: '0',
					style: 'border: none; background: #1a1a2e;'
				},
				listeners: {
					afterrender: function(box) {
						var iframe = document.getElementById(iframeId);
						if (iframe) {
							// Monitor iframe load events to detect navigation
							iframe.onload = function() {
								try {
									// Try to read iframe URL (may fail due to cross-origin)
									var iframeUrl = iframe.contentWindow.location.href;
									console.log('[PelicanPanel] iframe loaded: ' + iframeUrl);
								} catch(e) {
									// Cross-origin - can't read URL, but load succeeded
									console.log('[PelicanPanel] iframe loaded (cross-origin)');
								}
							};
						}
					}
				}
			}],

			// Toolbar with buttons
			tools: [{
				id: 'refresh',
				qtip: 'Rafraîchir',
				handler: function(event, element, panel) {
					var iframe = document.getElementById(iframeId);
					if (iframe) {
						iframe.src = iframeSrc;
					}
				}
			}, {
				id: 'help',
				qtip: 'Ouvrir dans un nouvel onglet',
				handler: function(event, element, panel) {
					window.open(directUrl, '_blank');
				}
			}]
		}, config);

		this.callParent([config]);
	}
});
