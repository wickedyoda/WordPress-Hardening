<?php
/**
 * Plugin Name: XML-RPC Hardening
 * Description: Removes the XML-RPC methods that make xmlrpc.php useful to an
 *              attacker, while leaving the endpoint itself reachable so that
 *              Jetpack keeps working.
 * Version:     1.0.0
 * Author:      wickedyoda
 *
 * Must-use plugin - auto-loaded, cannot be deactivated from the admin UI.
 *
 * WHY THE ENDPOINT IS NOT BLOCKED OUTRIGHT
 * ----------------------------------------
 * Jetpack is active on this site and references XML-RPC from its own sync and
 * remote-management code, so blocking xmlrpc.php entirely risks breaking it.
 * The abuse does not need the endpoint blocked - it needs the AMPLIFIER
 * removed, which is what this file does.
 *
 * WHAT WAS ACTUALLY HAPPENING (measured 2026-10-31, 7 days of proxy logs)
 * ----------------------------------------------------------------------
 *   xmlrpc.php POSTs .............. 22,799
 *   answered HTTP 200 ............. 22,359   <- processed, not blocked
 *   single busiest source ......... 10,000 requests from one Google Cloud IP
 *   second busiest ................ 9,807 from another
 *   share of ALL site traffic ..... roughly 20%
 *
 * `system.multicall` lets one HTTP request carry hundreds of method calls, so a
 * single connection attempts hundreds of passwords. That is why the request
 * count is huge while the attacker's cost is near zero. `wp.getUsersBlogs`
 * inside a multicall is the credential-stuffing method; `pingback.*` turns the
 * endpoint into a reflection DDoS amplifier.
 */

if (!defined('ABSPATH')) {
    exit;
}

/**
 * Strip the amplifier methods.
 *
 * Removed:
 *   system.multicall     - batches hundreds of calls into one request,
 *                          defeating per-request rate limits
 *   system.listMethods   - advertises exactly which methods are available
 *   system.getCapabilities
 *   pingback.*           - reflection DDoS vector
 *
 * Deliberately kept: authenticated single-call methods, so the WordPress
 * mobile app and any legitimate XML-RPC client still function.
 */
add_filter('xmlrpc_methods', function ($methods) {
    unset($methods['system.multicall']);
    unset($methods['system.listMethods']);
    unset($methods['system.getCapabilities']);

    foreach (array_keys($methods) as $method) {
        if (strpos($method, 'pingback.') === 0) {
            unset($methods[$method]);
        }
    }

    return $methods;
});
