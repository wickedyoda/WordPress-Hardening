# wordpress-hardened

A thin, hardened derivative of the **official** WordPress Docker image.

```
php:php8.3-apache  ->  wordpress:php8.3-apache  ->  ghcr.io/wickedyoda/wordpress-hardened
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

- **Site files live in a volume, so the image reconciles them at startup.**
  `/var/www/html` is declared `VOLUME` by the base image, so site files can never
  live in an image layer. The mu-plugins are therefore shipped to
  `/usr/src/wordpress/wp-content/mu-plugins/` (which the stock entrypoint copies
  into a **fresh** volume) **and** reconciled into the volume on every start by
  `entrypoint-hardening.sh`, which runs before the stock entrypoint and then
  `exec`s it unchanged.

  Without that wrapper a mu-plugin shipped in the image would reach a brand-new
  install but **never an existing site** — the fix would be published and silently
  not apply. The wrapper is idempotent, only ever touches files the image owns,
  and updates them when the image's copy differs. CI reproduces the real case: a
  populated volume missing one mu-plugin must gain it on start.
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
docker build -t wordpress-hardened:php8.3-apache .

# Pin the base by digest for a byte-exact, reproducible rebuild
docker build \
  --build-arg BASE_IMAGE=wordpress:php8.3-apache@sha256:<digest> \
  -t wordpress-hardened:php8.3-apache .
```

The build **fails loudly** if any hardening file is missing or if Apache cannot
parse the configuration, so a broken image can never be published.

### Automated pipeline — verify, build, then publish

`.github/workflows/build.yml` runs three jobs, and **publishing is the last
gate**: a failure anywhere upstream of `publish` means nothing is pushed.

**Gate 1 — `verify`** (static analysis, nothing is built until this is green):

| Check | Tool | Blocking |
|---|---|---|
| GitHub Actions workflow syntax and expressions | actionlint | **yes** |
| Workflow security audit | zizmor | advisory |
| YAML syntax | yamllint | **yes** |
| Dockerfile best practice | hadolint | **yes** |
| Committed secrets | gitleaks | **yes** |
| Dockerfile misconfiguration | Trivy config | advisory |
| PHP syntax of the mu-plugin | `php -l` | **yes** |
| PHP hardening ini actually applies | `php -r` assertion | **yes** |
| Apache hardening config parses | `apache2ctl -t` | **yes** |

**Gate 2 — `build`** (prove the artifact, not just the source):

- Builds the image and loads it locally — **nothing is pushed from this job**.
- **Smoke test**: runs the image with **no volumes and no bind mounts**, then
  asserts `readme.html`, `license.txt`, `wp-config-sample.php`, `.gitignore` and
  `wp-content/php-error.log` all return 403, that `X-Powered-By` is absent, and
  that `apache2ctl -t` passes. If the hardening were still living in compose,
  this job would fail.
- **Trivy image scan** — blocks on **fixable HIGH or CRITICAL**. The Dockerfile
  runs `apt-get upgrade`, so every advisory Debian has already patched is applied
  at build time and the fixable count is **0**; anything that appears is a
  regression worth stopping for. Unfixable advisories in the upstream base are
  reported but not gated — no work in this repo can clear them.

**`publish`** — runs only when both gates pass, and not on pull requests. Pushes
to `ghcr.io/wickedyoda/wordpress-hardened` with OCI provenance and SBOM
attestations.

Triggers: every push to `main`, every pull request (verify + build only, never
publish), a **weekly schedule** (Sundays 04:17 UTC) which is what keeps the image
in line with upstream WordPress and PHP security releases, and manual dispatch.

Every action is pinned to a full commit SHA rather than a mutable tag, so nobody
can repoint `@v7` at new code behind this repo's back.

**Why the gate is "fixable" rather than a raw count.** Measured on 2026-10-31:

| | before `apt-get upgrade` | after |
|---|---|---|
| Fixable HIGH | 36 | **0** |
| Fixable CRITICAL | 0 | **0** |
| Total HIGH (incl. unfixable) | 167 | 131 |
| Total CRITICAL (incl. unfixable) | 2 | 2 |

The upgrade moved ImageMagick `deb13u12 -> deb13u13` and cleared every advisory
Debian had already patched. What remains is **unfixable** — no fix has been
published — so gating on it would block every build forever without changing a
single byte. The gate therefore fires only on what can actually be acted on.

---

## Use it

Replace the `image:` line in your WordPress service:

```yaml
  wordpress:
    # was: image: wordpress:latest
    image: ghcr.io/wickedyoda/wordpress-hardened:php8.3-apache
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
hardening in the first place. Prefer `:php8.3-apache`, ideally by digest.

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

## A subtle trap: `xmlrpc_methods` cannot remove `system.multicall`

The first version of `xmlrpc-hardening.php` filtered `xmlrpc_methods`. **It did
not work, and the reason is worth knowing.**

`wp_xmlrpc_server` passes its filtered method array to `IXR_Server`, but
`IXR_Server::__construct()` calls `setCallbacks()` *after* storing it, and
`setCallbacks()` unconditionally re-registers three methods:

```php
$this->callbacks['system.getCapabilities'] = 'this:getCapabilities';
$this->callbacks['system.listMethods']     = 'this:listMethods';
$this->callbacks['system.multicall']       = 'this:multiCall';
```

So any filter on `xmlrpc_methods` is **silently defeated** for those three.
Verified live: with v1 deployed, a well-formed `system.multicall` still returned
a normal result. WordPress also exposes no action before dispatch that carries the
decoded method name — `xmlrpc_call` fires *inside* individual methods, which on a
multicall is already too late.

v2 therefore refuses the request on the **raw body**, before `IXR_Server` is
constructed, and normalises that body first (numeric character references
decoded, whitespace stripped) so `<methodName>system.multi&#99;all</methodName>`
cannot slip past a naive string match. Both the plain and the obfuscated form are
verified refused; legitimate single calls still work.

`pingback.*` **is** removable by the filter, because WordPress registers those
itself and `IXR_Server` does not re-add them.

---

## Layout

```
Dockerfile                      thin FROM wordpress:<ver>-apache + COPYs
apache-hardening.conf           -> /etc/apache2/conf-enabled/zz-hardening.conf
php-hardening.ini               -> /usr/local/etc/php/conf.d/zz-hardening.ini
mu-plugins/security_hardening.php        -> /usr/src/wordpress/wp-content/mu-plugins/
mu-plugins/xmlrpc-hardening.php          -> /usr/src/wordpress/wp-content/mu-plugins/
entrypoint-hardening.sh          -> /usr/local/bin/, runs before the stock entrypoint
                                    and reconciles mu-plugins into the volume
.github/workflows/build.yml     GHCR build + weekly upstream refresh
```

---

## A note on upstream tag names

The official WordPress image tags the Apache variant as `php8.3-apache`, **not**
`8.3-apache` — that approximation does not exist and fails the build with
`not found`. Always confirm against the registry before changing `BASE_IMAGE`:

```bash
# HTTP 200 means the tag is real; 404 means it is not
curl -s -o /dev/null -w '%{http_code}\n' \
  https://hub.docker.com/v2/repositories/library/wordpress/tags/php8.3-apache
```

Valid variants for the tag this repo uses: `php8.3-apache`, `php8.3`, `php8.3-fpm`,
`php8.3-fpm-alpine`, plus version-pinned forms such as `7.2-php8.3-apache`.

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
