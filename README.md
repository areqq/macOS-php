# macOS-php

Native (Apple Silicon, **arm64**) **PHP 5.6.40 + nginx** for modern macOS —
fully self-contained: no Docker, no Homebrew at runtime. The only libraries it
links outside its own prefix are the ones macOS always ships (`libSystem`,
`libc++`, `libresolv`, `libxml2`, `libicucore`).

Two ways to get it:

1. **Download prebuilt binaries** from GitHub Releases and let `install.sh`
   generate the local config + a self-signed TLS cert. No compiler needed.
2. **Build from source** with `compile-php.sh` (everything vendored from
   source into one prefix).

PHP 5.6 is EOL upstream; this uses Remi Collet's
[`php-src-security`](https://github.com/remicollet/php-src-security) fork
(CVE backports onto 5.6, built against OpenSSL 1.1.1).

Extensions: `intl, openssl, curl, mysqli, pdo_mysql, mysqlnd, mbstring, zip,
bcmath, exif, opcache` + `apcu` and `tideways_xhprof` (PECL). SAPIs: CLI
(with the built-in `php -S` server) and FPM.

> The bundle is **tied to its install prefix** (`/opt/php56` by default) via
> absolute `install_name`s. It must be extracted exactly there — `install.sh`
> handles that. To use a different prefix, build from source with `PREFIX=...`.

## Install prebuilt (recommended)

```bash
curl -fsSL https://raw.githubusercontent.com/areqq/macOS-php/main/install.sh -o install.sh
chmod +x install.sh
./install.sh                                   # latest release
# or a specific tag / a custom site:
SERVER_NAME=php.local PORT=8443 DOCROOT="$PWD/public" ./install.sh v1.0.0
```

`install.sh` downloads the release bundle, verifies its SHA-256, extracts it to
`/opt/php56` (asks for `sudo` only to create the dir), generates a self-signed
cert for `SERVER_NAME`, renders `nginx.conf` for your `DOCROOT`, and writes
`start.sh` / `stop.sh`.

```bash
/opt/php56/start.sh         # php-fpm + nginx  → https://localhost:8443/
/opt/php56/stop.sh
export PATH="/opt/php56/bin:$PATH"
php -v
```

If `SERVER_NAME` isn't `localhost`, add it to `/etc/hosts`:

```bash
echo "127.0.0.1 php.local" | sudo tee -a /etc/hosts
```

## Build from source

See **[BUILD.md](BUILD.md)** for the full process and the macOS-specific
pitfalls. Quick version:

```bash
./compile-php.sh            # full build → /opt/php56 (~30–40 min)
./compile-php.sh -l         # list steps
./compile-php.sh nginx config   # run selected steps only
./compile-php.sh dist       # pack a distribution archive
```

Version pins and paths live in [`versions.env`](versions.env); override any via
the environment (e.g. `PREFIX=/tmp/php ./compile-php.sh`).

## CI / releases

`.github/workflows/build.yml` builds on a hosted **`macos-14`** (arm64) runner.
Trigger manually (*Actions → build → Run workflow*) for an artifact, or push a
`vX.Y.Z` tag to build and publish a **GitHub Release** with the bundle +
`.sha256`. `install.sh` pulls from the latest release.

## Layout

```
macOS-php/
├── compile-php.sh            # source build (steps: prereqs … nginx … verify)
├── versions.env              # pinned versions + paths (override via env)
├── install.sh                # install prebuilt from Releases + local config/cert
├── etc/
│   ├── php.ini
│   ├── conf.d/{10-opcache,15-apcu,99-perf}.ini
│   ├── php-fpm.d/www.conf
│   └── nginx/nginx.conf.template
└── .github/workflows/build.yml
```
