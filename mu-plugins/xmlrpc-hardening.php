<?php
/**
 * Plugin Name: XML-RPC Hardening
 * Description: Rejects system.multicall on the raw request, and unregisters the
 *              pingback methods, while leaving xmlrpc.php reachable so Jetpack
 *              keeps working.
 * Version:     2.0.0
 * Author:      wickedyoda
 *
 * Must-use plugin - auto-loaded, cannot be deactivated from the admin UI.
 *
 * WHY VERSION 1.0 DID NOT WORK, AND WHY THIS ONE DOES
 * ---------------------------------------------------
 * 1.0 removed system.multicall by filtering `xmlrpc_methods`. That filter is
 * silently defeated for the three system.* methods. wp_xmlrpc_server passes its
 * filtered array to IXR_Server, and IXR_Server::__construct() calls
 * setCallbacks() AFTER storing it, which unconditionally re-registers:
 *
 *     $this->callbacks['system.getCapabilities'] = 'this:getCapabilities';
 *     $this->callbacks['system.listMethods']     = 'this:listMethods';
 *     $this->callbacks['system.multicall']       = 'this:multiCall';
 *
 * Verified live: with 1.0 deployed, a well-formed system.multicall still
 * returned a normal result. WordPress also exposes no action before dispatch
 * that carries the decoded method name - `xmlrpc_call` fires inside individual
 * methods, which for a multicall is already too late.
 *
 * 2.0 therefore refuses the request on the raw body, before IXR_Server is even
 * constructed. The body is normalised first (numeric character references
 * decoded, whitespace stripped) so that `<methodName>system.multi&#99;all`
 * cannot slip past a naive string match.
 *
 * WHAT THIS IS DEFENDING AGAINST (measured 2026-10-31, 7 days of proxy logs)
 * -------------------------------------------------------------------------
 *   22,799 POSTs to xmlrpc.php, 22,359 answered HTTP 200
 *   10,000 requests from one Google Cloud IP; 9,807 from a second
 *   roughly 20% of ALL traffic to the site
 * system.multicall lets one HTTP request carry hundreds of credential attempts,
 * which is why the request count is enormous and the attacker's cost is zero.
 */

if (!defined('ABSPATH')) {
    exit;
}

/**
 * Reject system.multicall outright, before WordPress dispatches anything.
 *
 * Only reads the request body for actual XML-RPC requests, and only ever blocks
 * on a positive match, so legitimate traffic cannot be affected by a read error.
 */
if (defined('XMLRPC_REQUEST') && XMLRPC_REQUEST) {
    $raw = @file_get_contents('php://input');

    if (is_string($raw) && $raw !== '') {
        // Decode numeric character references: &#99; and &#x63; both become "c".
        $norm = preg_replace_callback(
            '/&#(x?)([0-9A-Fa-f]+);/',
            static function ($m) {
                $code = $m[1] === '' ? (int) $m[2] : hexdec($m[2]);
                return $code > 0 && $code < 0x110000 ? mb_chr($code, 'UTF-8') : '';
            },
            $raw
        );
        if (!is_string($norm)) {
            $norm = $raw;
        }
        // Whitespace cannot legally appear inside an XML method name, so
        // removing it defeats nothing legitimate.
        $norm = preg_replace('/\s+/', '', $norm);

        if (stripos($norm, 'system.multicall') !== false) {
            if (!headers_sent()) {
                header('Content-Type: text/xml; charset=UTF-8');
                header('X-Hardening: xmlrpc-multicall-refused');
            }
            echo '<?xml version="1.0" encoding="UTF-8"?>' . "\n";
            echo "<methodResponse>\n<fault>\n<value>\n<struct>\n";
            echo "<member><name>faultCode</name><value><int>-32601</int></value></member>\n";
            echo "<member><name>faultString</name><value><string>";
            echo "system.multicall is disabled on this server.";
            echo "</string></value></member>\n";
            echo "</struct>\n</value>\n</fault>\n</methodResponse>\n";
            exit;
        }
    }
}

/**
 * Drop the pingback methods. This filter DOES work - unlike the system.*
 * methods, pingback.* is registered by WordPress itself and not re-added by
 * IXR_Server, so removing it here is effective.
 */
add_filter('xmlrpc_methods', static function ($methods) {
    foreach (array_keys((array) $methods) as $method) {
        if (strpos($method, 'pingback.') === 0) {
            unset($methods[$method]);
        }
    }
    return $methods;
});
