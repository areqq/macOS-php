# macOS-php / php85

Native (Apple Silicon, **arm64**) **PHP 8.5 + nginx** for modern macOS — fully
self-contained: no Docker, no Homebrew at runtime. Sibling of the PHP 5.6 build
in the repo root; same approach, different version.

Extension set (production-minimal): `mysqli`, `pdo_mysql`, `mysqlnd`,
`mbstring`, `curl`, `dom`/`simplexml`/`xml*`, `iconv`, `apcu`, `opcache` (with
**JIT**). Deliberately excluded: `intl`, `zip`, `bcmath`, `exif`, `gd`.

Vendored from source into `/opt/php8.5` with absolute `install_name`s: OpenSSL 3,
zlib, libiconv, oniguruma (mbstring regex), curl. pcre2 is linked statically
into nginx. libxml2 comes from the macOS SDK (always present). The only
libraries linked outside the prefix are ones macOS always ships.

## Install prebuilt

```bash
curl -fsSL https://raw.githubusercontent.com/areqq/macOS-php/main/php85/install.sh -o install.sh
chmod +x install.sh
./install.sh                                   # latest php8.5 release
SERVER_NAME=php.local PORT=8543 DOCROOT="$PWD/public" ./install.sh php85-v1.0.0
```

`install.sh` downloads the release bundle, verifies its SHA-256, extracts it to
`/opt/php8.5`, generates a self-signed cert, renders `nginx.conf`, and writes
`start.sh` / `stop.sh`.

```bash
/opt/php8.5/start.sh        # php-fpm + nginx → https://localhost:8543/
/opt/php8.5/stop.sh
export PATH="/opt/php8.5/bin:$PATH"
php -v
```

## Build from source

```bash
cd php85
./compile-php.sh            # full build → /opt/php8.5
./compile-php.sh -l         # list steps
./compile-php.sh dist       # pack a distribution archive
```

Why PHP 8.5 is far simpler to build than 5.6: it uses a modern autoconf, builds
against OpenSSL 3, needs no `-Wno-error` clang workarounds, and — since `intl`
is excluded — needs no ICU at all. The one macOS-specific wrinkle: PHP 8.x
detects libxml only via pkg-config, so `compile-php.sh` (step `confaux`)
generates a `libxml-2.0.pc` pointing at the SDK's libxml2.

## CI / releases

`.github/workflows/build-php85.yml` builds on `macos-14` (arm64). Trigger
manually for an artifact, or push a **`php85-vX.Y.Z`** tag to build and publish
a GitHub Release. (The PHP 5.6 build uses plain `vX.Y.Z` tags — the two don't
collide.)

## Versions

Pins live in [`versions.env`](versions.env); override any via the environment.
