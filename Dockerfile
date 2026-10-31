#
# wickedyoda/wordpress-hardened
# ===========================================================================
# A THIN, hardened derivative of the official WordPress Docker image.
#
# Layer chain:   php:8.3-apache  ->  wordpress:8.3-apache  ->  THIS IMAGE
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
#   docker build --build-arg BASE_IMAGE=wordpress:8.3-apache@sha256:... .
ARG BASE_IMAGE=wordpress:8.3-apache
FROM ${BASE_IMAGE}

LABEL org.opencontainers.image.title="wordpress-hardened" \
      org.opencontainers.image.description="Official WordPress image with Apache and PHP hardening baked in" \
      org.opencontainers.image.source="https://github.com/wickedyoda/WordPress-Hardening" \
      org.opencontainers.image.licenses="GPL-3.0-or-later" \
      org.opencontainers.image.base.name="docker.io/library/wordpress"

# --- Apache hardening ------------------------------------------------------
# /etc/apache2/apache2.conf line 222 has:  IncludeOptional conf-enabled/*.conf
# That include sits AFTER the stock <Directory /var/www/> block at ~line 170,
# so the directives in this file override the image defaults. The .conf suffix
# is mandatory - conf-enabled only globs *.conf.
COPY apache-hardening.conf /etc/apache2/conf-enabled/zz-hardening.conf

# --- PHP hardening --------------------------------------------------------
# Read by the Apache PHP module at startup, alongside the stock
# docker-php-ext-*.ini files. Deliberately only sets security-relevant keys,
# so a mounted php-custom.ini keeps ownership of upload/resource limits.
COPY php-hardening.ini /usr/local/etc/php/conf.d/zz-hardening.ini

# --- Site files for a FRESH volume ---------------------------------------
# /var/www/html is declared VOLUME by the base image, so site files can never
# live there in an image. The base entrypoint copies /usr/src/wordpress/* into
# the volume ONLY when the volume is empty, so baking the mu-plugin here means
# a brand-new install is hardened from first boot. On an existing volume this
# is inert and harmless.
COPY --chown=www-data:www-data mu-plugins/ /usr/src/wordpress/wp-content/mu-plugins/

# --- Build-time verification ---------------------------------------------
# Fail the build loudly if any hardening file failed to land, and prove Apache
# can actually parse the config before this image is ever run.
RUN set -eux; \
    test -s /etc/apache2/conf-enabled/zz-hardening.conf; \
    test -s /usr/local/etc/php/conf.d/zz-hardening.ini; \
    test -s /usr/src/wordpress/wp-content/mu-plugins/security_hardening.php; \
    apache2ctl -t

# ENTRYPOINT ["docker-entrypoint.sh"] and CMD ["apache2-foreground"] are
# inherited from the base image unchanged.
