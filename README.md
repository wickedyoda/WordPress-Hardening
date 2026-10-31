# wordpress-hardened

A thin, hardened derivative of the **official** WordPress Docker image.

```
php:8.3-apache  ->  wordpress:8.3-apache  ->  ghcr.io/wickedyoda/wordpress-hardened
```

This repository does **not** fork or re-generate
[`docker-library/wordpress`](https://github.com/docker-library/wordpress). It adds
a handful of configuration files on top of the official image, which stays the
source of truth for WordPress, PHP and Apache.

---

## Why this exists

The hardening used to live in two fragile places:

1. **Hand-edits made inside the running container.** On 2026-10-29 the container
   was recreated and every container-layer edit vanished:
   `AllowOverride` reverted to `None` (so `.htaccess` went silently inert) and
   `X-Powered-By: PHP/8.3.x` came back in every response.
2. **Bind mounts from the host.** Durable, but only while the compose file is
   correct. A rebuilt compose file, a bare `docker run`, or a fresh host loses
   the hardening entirely.

The public site looked perfectly healthy throughout, which is exactly why it
went unnoticed for days.

Baking the configuration into the image makes it **intrinsic**. It survives
container recreation, a forgotten mount, and a plain `docker run`.

---

## What this hardens

| # | Control | File | Why it matters |
|---|---------|------|----------------|
| 1 | `AllowOverride All` | `apache-hardening.conf` | The stock image ships `AllowOverride None`, which silently disables **every** `.htaccess` directive while the site still works. Without this, `.htaccess` is decorative. |
| 2 | `php_admin_flag expose_php off` | `apache-hardening.conf` | Removes `X-Powered-By: PHP/8.3.36`. That header hands an attacker the exact PHP version to target. |
| 3 | `ServerTokens Prod` / `ServerSignature Off` | `apache-hardening.conf` | Stops Apache advertising its version, modules and OS. |
| 4 | Info-disclosure file block | `apache-hardening.conf` | Denies `readme.html` and `license.txt` (exact WordPress version), `wp-config-sample.*`, `wp-config.php.bak|old|save|txt`, and any dotfile. Enforced in Apache config, so it holds even if `.htaccess` is lost. |
| 5 | `Options -Indexes` | `apache-hardening.conf` | No auto-generated directory listings for folders lacking an index. |
| 6 | No PHP in uploads | `apache-hardening.conf` | Blocks the classic webshell path: upload `image.php`, then request it. Any `.php`/`.phtml`/`.phar` under `wp-content/uploads` is denied. |
| 7 | `expose_php = Off`, `display_errors = Off` | `php-hardening.ini` | Stack traces leak absolute paths, DB details and plugin internals. Errors are still logged, never displayed. |
| 8 | `allow_url_include = Off` | `php-hardening.ini` | Closes the LFI-to-RCE upgrade path. `allow_url_fopen` stays `On` because WordPress core needs it. |
| 9 | Session cookie hardening | `php-hardening.ini` | `httponly`, `use_only_cookies`, `use_strict_mode`. Defence in depth for plugins that use PHP sessions. |
| 10 | Anonymous REST API blocked (401) | `mu-plugins/security_hardening.php` | Stops anonymous enumeration of installed plugins, their versions and endpoints. Also strips `wp_generator`, `rsd_link`, `wlwmanifest_link` and oEmbed discovery links from `<head>`. |
| 11 | Log / backup / config file block | `apache-hardening.conf` | Denies `.log`, `.sql`, `.bak`, `.old`, `.ini`, `.yml`, `.tar`, `.zip` and similar. Not theoretical — see *Found on the live site* below. |

---

## Found on the live site

The first real finding came from testing the image rather than trusting it.

`https://www.wickedyoda.com/wp-content/php-error.log` returned **HTTP 200 with
501,495 bytes** to anyone who asked. `php-custom.ini` sets
`error_log = /var/www/html/wp-content/php-error.log` — inside the document root,
which is web-servable. Contents:

| Disclosed | Count |
|---|---|
| Lines of log | 4,387 |
| PHP fatal errors | 235 |
| PHP warnings | 206 |
| Absolute filesystem paths | 34 distinct (4,503 occurrences) |
| Stack traces / call sites | 679 |

No database credentials, email addresses or client IPs were present — but the
absolute paths alone map the server's layout, and the fatals name the exact
code paths that are breaking.

Control 11 closes it at the Apache layer, so the log file itself can stay where
it is and any tooling that tails it keeps working. **The root-cause fix is to
move `error_log` out of the document root** (e.g. `/var/log/php-error.log`
inside the container); the block is there so a future misconfiguration in any
other `.log` or backup file is not exposed either.

---

## What this deliberately does NOT do

Being honest about the boundaries matters more than the feature list.

- **It cannot bake anything into `/var/www/html`.** That path is declared
  `VOLUME` by the base image, so it is data, not image content. The mu-plugin is
  copied to `/usr/src/wordpress/wp-content/mu-plugins/` instead — which the base
  entrypoint copies into the volume **only when the volume is empty**. On an
  existing site the image's copy is inert. That is intentional, not a gap:
  it means a brand-new install is hardened from first boot, while a live site
  is never overwritten.
- **It does not disable XML-RPC.** That block ships commented out, because it can
  break Jetpack and the WordPress mobile app. See the bottom of
  `apache-hardening.conf`.
- **It does not touch the database, the NPM reverse proxy, or TLS.** Security
  headers (HSTS, CSP, `X-Frame-Options`) are set at the nginx proxy layer and
  are out of scope here.
- **`AllowOverride All` is deliberately broad.** It is scoped to `/var/www/`
  to preserve the behaviour that is already proven working. `.htaccess` support
  is required because the live site's security blocks live there.

---

## Build

```bash
# Default base (PHP 8.3, matching the live container)
docker build -t wordpress-hardened:8.3-apache .

# Pin the base by digest for a byte-exact, reproducible rebuild
docker build \
  --build-arg BASE_IMAGE=wordpress:8.3-apache@sha256:<digest> \
  -t wordpress-hardened:8.3-apache .
```

The build **fails loudly** if any hardening file is missing or if Apache cannot
parse the configuration, so a broken image can never be published.

### Automated builds

Every action in the workflow is pinned to a full commit SHA rather than a
mutable tag, so nobody can repoint `@v7` at new code behind this repo's back.

`.github/workflows/build.yml` builds and pushes to
`ghcr.io/wickedyoda/wordpress-hardened` on every push to `main`, and on a
**weekly schedule**. The schedule is what keeps this in line with upstream:
WordPress and PHP security releases are picked up automatically, with no
rebasing and no generated Dockerfiles to maintain.

---

## Use it

Replace the `image:` line in your WordPress service:

```yaml
  wordpress:
    # was: image: wordpress:latest
    image: ghcr.io/wickedyoda/wordpress-hardened:8.3-apache
    container_name: wickedyoda-wp
    restart: unless-stopped
```

Once the image carries the Apache drop-in, the `apache-hardening.conf` bind
mount becomes redundant and can be removed:

```yaml
      # - ./apache-hardening.conf:/etc/apache2/conf-enabled/zz-hardening.conf:ro   # superseded by the image
      - ./php-custom.ini:/usr/local/etc/php/conf.d/zz-custom.ini:ro                # keep: upload/resource limits
```

**Pin the tag.** `wordpress:latest` is a floating tag; a recreate silently pulled
a newer image and that is what rebuilt the container layer and reverted the
hardening in the first place. Prefer `:8.3-apache`, ideally by digest.

---

## Verify it worked

Run these on the **container**, not the public URL — a reverse proxy will mask
the result for some paths, which is how the original revert went unnoticed.

```bash
# AllowOverride is actually All (proves .htaccess is live)
docker exec <container> sh -c 'apachectl -t -D DUMP_RUN_CFG' | grep -i allowoverride

# Info-disclosure files are blocked
docker exec <container> curl -s -o /dev/null -w '%{http_code}\n' localhost/readme.html   # 403
docker exec <container> curl -s -o /dev/null -w '%{http_code}\n' localhost/license.txt   # 403

# PHP version is not advertised
docker exec <container> curl -sI localhost/ | grep -i x-powered-by                     # (no output)

# Config parses
docker exec <container> apache2ctl -t                                                   # Syntax OK

# PHP hardening is live in the APACHE SAPI (CLI reads different ini rules)
docker exec <container> sh -c 'echo "<?php phpinfo();" > /tmp/i.php && cp /tmp/i.php /var/www/html/i.php'
curl -s https://<site>/i.php | grep -i expose_php     # expose_php => Off
docker exec <container> rm -f /var/www/html/i.php
```

---

## Layout

```
Dockerfile                      thin FROM wordpress:<ver>-apache + COPYs
apache-hardening.conf           -> /etc/apache2/conf-enabled/zz-hardening.conf
php-hardening.ini               -> /usr/local/etc/php/conf.d/zz-hardening.ini
mu-plugins/security_hardening.php
                                -> /usr/src/wordpress/wp-content/mu-plugins/
.github/workflows/build.yml     GHCR build + weekly upstream refresh
```

---

## Tracking upstream

To move to a new PHP or WordPress release:

1. Edit the default of `ARG BASE_IMAGE` in the `Dockerfile` (or pass
   `--build-arg`).
2. Push. CI rebuilds and retags.

That is the whole process. There is no generator to re-run and no merge conflict
to resolve, because this repository never contains a copy of upstream's files.

---

## Licence

GPL-3.0-or-later, matching the WordPress project.
