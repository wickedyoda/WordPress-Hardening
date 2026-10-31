<?php
/**
 * Plugin Name: Security Hardening
 * Description: Restricts the WordPress REST API for unauthenticated users and
 *              removes version/identity metadata from the document head.
 * Version:     1.0.0
 * Author:      wickedyoda
 *
 * Must-use plugin - loaded automatically, cannot be deactivated from the
 * admin UI. Baked into the image at /usr/src/wordpress/wp-content/mu-plugins/
 * so that a FRESH volume is hardened from first boot.
 *
 * TRADE-OFF: this blocks the ENTIRE anonymous REST API (401), not just the
 * namespace listing that leaks installed plugins. That is correct for a
 * brochure/gallery site with no public API consumers, but it DOES break
 * oEmbed previews of this site elsewhere (e.g. pasting a URL into Slack or
 * Discord will not unfurl). Remove the rest_authentication_errors filter
 * below if you ever need the public REST API back.
 */

if (!defined('ABSPATH')) {
    exit;
}

// Restrict the REST API to authenticated users only. This stops anonymous
// enumeration of installed plugins, their versions and their endpoints.
add_filter('rest_authentication_errors', function ($result) {
    if (!empty($result)) {
        return $result;
    }
    if (!is_user_logged_in()) {
        return new WP_Error(
            'rest_forbidden',
            'REST API restricted.',
            array('status' => 401)
        );
    }
    return $result;
});

// Remove the WordPress version and other identity metadata from <head>.
// wp_generator prints the exact version, which is a free heads-up for an
// attacker choosing an exploit.
remove_action('wp_head', 'wp_generator');
remove_action('wp_generator', 'wp_generator');
remove_action('wp_head', 'wlwmanifest_link');
remove_action('wp_head', 'rsd_link');
remove_action('wp_head', 'wp_shortlink_wp_head');

// Remove oEmbed discovery links from <head>.
remove_action('wp_head', 'wp_oembed_add_discovery_links');
