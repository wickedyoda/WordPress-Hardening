#
# wickedyoda/wordpress-hardened
# ===========================================================================
# A THIN, hardened derivative of the official WordPress Docker image.
#
# Layer chain:   php:8.3-apache  ->  wordpress:php8.3-apache  ->  THIS IMAGE
#
# This does NOT fork or re-generate docker-library/wordpress. It only ADDS
# configuration files on top of the official image, so staying in line with
# upstream means changing one ARG and rebuilding. There is no template
# pipeline, no apply-templates.sh, and no generated Dockerfile to rebase.
#
# WHY THIS EXISTS
# ---------------
# The hardening previously lived in hand-edits made *inside* the running
# container, plus bind mounts from the host. On 2026-10-29 the container was
# recreated and every container-layer edit silently vanished:
#     AllowOverride reverted to None  -> .htaccess went inert
#     php_admin_flag expose_php       -> X-Powered-By: PHP/8.3.x returned
# The public site still looked completely healthy, so nobody noticed.
# Baking the configuration into the image makes it intrinsic: it survives
# recreation, a forgotten mount, or a bare `docker run`.
# ===========================================================================

# Bump this to track upstream (or pin by digest for byte-exact rebuilds):
#   docker build --build-arg BASE_IMAGE=wordpress:php8.3-apache@sha256:... .
ARG BASE_IMAGE=wordpress:php8.3-apache
FROM ${BASE_IMAGE}

LABEL org.opencontainers.image.title="wordpress-hardened" \
      org.opencontainers.image.description="Official WordPress image with Apache and PHP hardening baked in" \
      org.opencontainers.image.source="https://github.com/wickedyoda/WordPress-Hardening" \
      org.opencontainers.image.licenses="GPL-3.0-or-later" \
      org.opencontainers.image.base.name="docker.io/library/wordpress"

# --- Apply upstream Debian security updates --------------------------------
# Scanned raw, this base image carries 36 HIGH advisories that Debian has
# already published fixes for - the image simply lags. Upgrading here clears
# them instead of shipping known-vulnerable packages.
#
# hadolint's DL3005 warns that apt-get upgrade can move dependencies underneath
# you. That is accepted deliberately: this image is a leaf artifact, and CI runs
# a functional smoke test against the built result, so a regression is caught
# before publication rather than in production.
# hadolint ignore=DL3005
RUN set -eux; \
    apt-get update; \
    apt-get upgrade -y; \
    rm -rf /var/lib/apt/lists/*

# --- A writable log directory OUTSIDE the document root --------------------
# The host's php-custom.ini wrote the PHP error log to
# /var/www/html/wp-content/php-error.log - inside the web root. That file was
# being served publicly: HTTP 200 with 501,495 bytes, 4,387 lines, 34 absolute
# filesystem paths and 679 stack traces, readable from 2026-08-28 until it was
# blocked. php-hardening.ini now points error_log here instead, so the cause is
# fixed rather than merely blocked.
RUN install -d -o www-data -g www-data -m 0750 /var/log/php

# --- Apache hardening ------------------------------------------------------
# /etc/apache2/apache2.conf line 222 has:  IncludeOptional conf-enabled/*.conf
# That include sits AFTER the stock <Directory /var/www/> block at ~line 170,
# so the directives in this file override the image defaults. The .conf suffix
# is mandatory - conf-enabled only globs *.conf.
COPY apache-hardening.conf /etc/apache2/conf-enabled/zz-hardening.conf

# --- PHP hardening --------------------------------------------------------
# Read by the Apache PHP module at startup, alongside the stock
# docker-php-ext-*.ini files. Sorts last in conf.d, so it wins over a mounted
# php-custom.ini where the two overlap.
COPY php-hardening.ini /usr/local/etc/php/conf.d/zz-hardening.ini

# --- Site files for a FRESH volume ---------------------------------------
# /var/www/html is declared VOLUME by the base image, so site files can never
# live there in an image. The base entrypoint copies /usr/src/wordpress/* into
# the volume ONLY when the volume is empty, so baking the mu-plugins here means
# a brand-new install is hardened from first boot. On an existing volume this
# is inert and harmless.
COPY --chown=www-data:www-data mu-plugins/ /usr/src/wordpress/wp-content/mu-plugins/

# --- Build-time verification ---------------------------------------------
# Fail the build loudly if any hardening file failed to land, prove Apache can
# parse the config, and prove the error log is NOT under the document root.
RUN set -eux; \
    test -s /etc/apache2/conf-enabled/zz-hardening.conf; \
    test -s /usr/local/etc/php/conf.d/zz-hardening.ini; \
    test -s /usr/src/wordpress/wp-content/mu-plugins/security_hardening.php; \
    test -s /usr/src/wordpress/wp-content/mu-plugins/xmlrpc-hardening.php; \
    test -d /var/log/php; \
    test "$(stat -c '%U' /var/log/php)" = "www-data"; \
    grep -qE '^error_log[[:space:]]*=[[:space:]]*/var/log/php/error\.log' \
        /usr/local/etc/php/conf.d/zz-hardening.ini; \
    if grep -qE '^[[:space:]]*error_log[[:space:]]*=[[:space:]]*/var/www' \
        /usr/local/etc/php/conf.d/zz-hardening.ini; then \
        echo "FATAL: an active error_log directive points inside the document root"; \
        exit 1; \
    fi; \
    apache2ctl -t

# --- Make the mu-plugins reach an EXISTING volume too ----------------------
# The base entrypoint only populates /var/www/html when the volume is empty, so
# without this wrapper a mu-plugin shipped here would never reach a running
# site. The wrapper reconciles them then hands over to the stock entrypoint
# unchanged. CI's smoke test runs this very path from a clean volume.
COPY --chown=root:root entrypoint-hardening.sh /usr/local/bin/entrypoint-hardening.sh
RUN chmod 0755 /usr/local/bin/entrypoint-hardening.sh

ENTRYPOINT ["entrypoint-hardening.sh"]
CMD ["apache2-foreground"]
