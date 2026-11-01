#!/bin/sh
#
# wickedyoda/wordpress-hardened  --  mu-plugin deployment wrapper.
#
# WHY THIS EXISTS
# ---------------
# The base image declares /var/www/html as a VOLUME, and its own entrypoint
# copies /usr/src/wordpress/* into the volume ONLY when the volume is empty.
# That means a mu-plugin baked into the image reaches a brand-new install but
# NEVER an existing site - so a fix shipped in the image would silently fail to
# apply to the running container. That is the same class of bug this whole
# project exists to eliminate.
#
# This wrapper runs BEFORE the stock entrypoint and reconciles the hardening
# mu-plugins into the volume. It is idempotent and it only ever touches files
# the IMAGE owns - anything else in mu-plugins/ is left alone.
#
# Files are updated when the image's copy differs, not merely when missing,
# because the image is the source of truth for hardening code. Local edits to
# these particular files would be overwritten by design.
#
set -eu

SRC=/usr/src/wordpress/wp-content/mu-plugins
DEST=/var/www/html/wp-content/mu-plugins

if [ -d /var/www/html/wp-content ] && [ -d "$SRC" ]; then
    mkdir -p "$DEST"
    for src in "$SRC"/*.php; do
        [ -e "$src" ] || continue
        name=$(basename "$src")
        dest="$DEST/$name"

        if [ ! -e "$dest" ]; then
            cp -a "$src" "$dest"
            echo "[hardening] deployed mu-plugin: $name"
        elif ! cmp -s "$src" "$dest"; then
            cp -a "$src" "$dest"
            echo "[hardening] updated mu-plugin from the image: $name"
        fi

        chown www-data:www-data "$dest" 2>/dev/null || true
    done
fi

# Hand over to the stock WordPress entrypoint unchanged.
exec docker-entrypoint.sh "$@"
