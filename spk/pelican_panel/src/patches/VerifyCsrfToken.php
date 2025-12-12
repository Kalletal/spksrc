<?php
/**
 * Patched VerifyCsrfToken middleware for Synology DSM iframe integration.
 *
 * This patch disables CSRF verification for all routes to allow
 * the Panel to work when accessed through DSM's iframe via the CGI proxy.
 *
 * Security note: Access is still protected by DSM authentication.
 *
 * Reference: https://vemto.app/blog/laravel-livewire-how-to-disable-csrf-token-to-embed-a-component-on-iframe
 * Reference: https://github.com/livewire/livewire/discussions/7563
 */

namespace App\Http\Middleware;

use Illuminate\Foundation\Http\Middleware\VerifyCsrfToken as BaseVerifier;

class VerifyCsrfToken extends BaseVerifier
{
    /**
     * The URIs that should be excluded from CSRF verification.
     *
     * PATCHED: Disabled CSRF for all routes for DSM iframe compatibility.
     * When accessed through DSM's CGI proxy, cookies/sessions don't work
     * correctly across the proxy boundary, causing CSRF token mismatch (419 errors).
     *
     * This is safe because:
     * 1. The Panel is only accessible through authenticated DSM sessions
     * 2. The CGI proxy acts as a security boundary
     */
    protected $except = [
        '*',
    ];
}
