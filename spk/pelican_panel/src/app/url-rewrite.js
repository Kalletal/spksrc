// URL Rewriter for Pelican Panel CGI Proxy
// Intercepts fetch and XHR to rewrite absolute paths to relative paths
// This allows Livewire/AJAX to work through the CGI proxy
(function() {
    'use strict';

    // Intercept fetch
    var originalFetch = window.fetch;
    window.fetch = function(input, init) {
        if (typeof input === 'string' && input.charAt(0) === '/') {
            input = '.' + input;
        }
        return originalFetch.call(this, input, init);
    };

    // Intercept XMLHttpRequest
    var originalXHROpen = XMLHttpRequest.prototype.open;
    XMLHttpRequest.prototype.open = function(method, url) {
        if (typeof url === 'string' && url.charAt(0) === '/') {
            arguments[1] = '.' + url;
        }
        return originalXHROpen.apply(this, arguments);
    };
})();
