# macOS-php — building the toolchain

How to build native (Apple Silicon, **arm64**) **PHP 5.6.40 + nginx** into
`/opt/php56` on modern macOS — everything from source, one command, repeatable
from scratch. For installing prebuilt binaries instead, see [README.md](README.md).

```bash
./compile-php.sh            # full build from scratch
./compile-php.sh -l         # list steps
./compile-php.sh verify     # just verify an existing build
```

First build: ~30–40 min (compiles PHP + OpenSSL + ICU + libiconv + zlib + curl +
autoconf 2.69 from source). Result:

```
/opt/php56/bin/php        # CLI (also gives `php -S host:port` — built-in HTTP server)
/opt/php56/sbin/php-fpm   # FPM
/opt/php56/sbin/nginx     # nginx
```

## What you get

- **PHP 5.6.40** from Remi Collet's
  [`PHP-5.6-security-backports-openssl11`](https://github.com/remicollet/php-src-security/tree/PHP-5.6-security-backports-openssl11)
  branch (CVE backports from newer lines, adapted to OpenSSL 1.1).
- **SAPIs**: CLI (incl. the built-in `php -S` server) + FPM.
- **Extensions**: `intl`, `openssl`, `curl`, `mysqli`, `mysqlnd`, `pdo_mysql`,
  `mbstring`, `zip`, `bcmath`, `exif`, `Zend OPcache`, `iconv`,
  `dom`/`simplexml`/`xml*`, `fileinfo`, `hash`, `session`, `tokenizer`,
  `reflection`, `json`, … `+ APCu 4.0.11` and `Tideways/XHProf 3.0.3` (PECL).
- **Deliberately disabled**: `gd`, `ldap`, `mcrypt`, `soap`, `pdo_sqlite`,
  `phar`, `readline`, `pear`.

The result is **self-contained**: OpenSSL 1.1.1w, ICU 66.1, GNU libiconv 1.17,
zlib 1.3.1 and curl 8.17.0 are compiled into the same prefix with **absolute
`install_name`s** → it runs without Homebrew and without `DYLD_*` (the only
system deps are `libSystem`, `libc++`, `libresolv`, and `libxml2`/`libicucore`
from the SDK).

## Requirements

- Apple Silicon (arm64), macOS with Command Line Tools (`xcode-select --install`).
- [Homebrew](https://brew.sh) (the script installs `re2c`, `autoconf`, `bison`,
  `pkg-config`, `pcre2`).
- `sudo` **once** — to create `/opt/php56` (then `chown` to the user). To avoid
  sudo: `PREFIX=$HOME/php5.6 ./compile-php.sh`.

## Steps (`compile-php.sh -l`)

| Step | What it does |
|---|---|
| `prereqs`     | brew (re2c/autoconf/bison/pkg-config/pcre2), creates `$PREFIX` |
| `autoconf269` | builds autoconf 2.69 locally (see pitfalls) |
| `confaux`     | arm64-aware `config.sub/guess` + `xml2-config` shim |
| `openssl`     | OpenSSL 1.1.1w → `$PREFIX` |
| `icu`         | ICU 66.1 (`-headerpad…`) + `install_name` fixup → `$PREFIX` |
| `libiconv`    | GNU libiconv 1.17 → `$PREFIX` |
| `zlib`        | zlib 1.3.1 → `$PREFIX` |
| `curl`        | curl 8.17.0 (OpenSSL backend) → `$PREFIX` |
| `php`         | clone + buildconf (ac 2.69) + configure + make + install |
| `pecl`        | APCu 4.0.11 + Tideways/XHProf 3.0.3 |
| `nginx`       | nginx 1.31.1 from source (OpenSSL 1.1.1w + pcre2) → `$PREFIX` |
| `config`      | installs `php.ini`, `conf.d/*`, FPM pool, base `nginx.conf` |
| `verify`      | `php -v/-m`, `php -S` smoke, `php-fpm -t`, `nginx -t`, extension check |

**Optional** steps (outside the defaults, run explicitly):

| Step | What it does |
|---|---|
| `slim`        | **destructively** minimizes `$PREFIX` (drops headers, `.a`, `phpize`/`php-config`…); afterwards you can no longer build extensions |
| `dist`        | packs `$PREFIX` into a distribution archive (see [Distribution](#distribution)) — does **not** destroy the prefix |

Versions and paths: [`versions.env`](versions.env) (override any via the environment).

## Build configuration

Files in [`etc/`](etc) go to `$PREFIX/etc/php/` (`php.ini`, `conf.d/`),
`$PREFIX/etc/php-fpm.d/`, and `$PREFIX/etc/nginx/`. Defaults lean toward **local
dev**:

- `display_errors = On`, `error_reporting = E_ALL`,
- `opcache.validate_timestamps = 1` (code changes picked up without an FPM restart),
- `session.cookie_secure = 0` (sessions work over plain HTTP, e.g. `php -S`),
- `apc.enable_cli = 1`,
- FPM listens on `$PREFIX/var/run/php-fpm.sock`, logs in `$PREFIX/var/log/`.

`Tideways/XHProf` is **built but not loaded**. To enable:
```
echo "extension=tideways_xhprof.so" > /opt/php56/etc/php/conf.d/20-tideways.ini
```

### Trimming ICU data (`ICU_LOCALES`)

Full ICU data makes `libicudata` ~**27 MB**. `ICU_LOCALES` (from
[`versions.env`](versions.env), default `en`) builds data for only the chosen
languages, shrinking it sharply. The language filter trims locale resources
only; shared data (conversion tables `*.cnv`, time zones, Unicode properties,
root collation) stays.

Mechanism (step `icu`): the `ICU_DATA_FILTER_FILE` filter applies **only** when
data is built from source, and the `-src` tarball ships a prebuilt
`icudt66l.dat`. So with `ICU_LOCALES` set, the build fetches
`icu4c-<v>-data.zip` (raw `.txt`), removes the prebuilt `.dat`, and rebuilds
with the filter (ICU 66 → `whitelist` key). `ICU_LOCALES=` (empty) = full data.
Add languages if `intl` needs them (e.g. `ICU_LOCALES="en de fr"`).

## Smoke test / CLI usage

```bash
export PATH="/opt/php56/bin:$PATH"

php -v
php -S 127.0.0.1:8000 -t public/                 # built-in HTTP server
php-fpm -F -y /opt/php56/etc/php-fpm.conf         # FPM in the foreground
```

## Why this is non-trivial — pitfalls and fixes

PHP 5.6 (EOL 2018) on a current macOS / clang / arm64 hits a string of
incompatibilities. Each is encoded in `compile-php.sh`; here is the "why".

| # | Problem | Symptom | Fix |
|---|---|---|---|
| 1 | **Homebrew dropped `openssl@1.1`** | no libssl 1.1; the PHP branch targets 1.1, not 3.0 | OpenSSL 1.1.1w from source into `$PREFIX` (`Configure darwin64-arm64-cc`) |
| 2 | **brew ICU too new for ext/intl 5.6** | intl won't compile (C++ API) | ICU 66.1 from source, `-std=c++11`, `-DU_USING_ICU_NAMESPACE=1` |
| 3 | **macOS SDK ships only `libiconv.tbd`** (stub) | `configure: Please reinstall the iconv library` (tests `-f libiconv.dylib`) | GNU libiconv 1.17 from source into `$PREFIX` |
| 4 | **system bison too old** | `configure: bison version invalid (min 2.4)` | brew bison on PATH (the fork supports ≥2.4, ≠3.0) |
| 5 | **brew autoconf mis-expands PHP 5.6 m4** | `configure: line N: syntax error near 'fi'` (PTHREADS macro) | autoconf **2.69** from source; `buildconf` with it, regenerate `configure` |
| 6 | **autoconf 2.69 has a 2012 `config.sub`** | doesn't know `arm64-apple-darwin` | `config.sub/guess` from **brew autoconf** copied into the source tree |
| 7 | **modern clang: implicit-func-decl = error** | `configure` tests falsely "no" → wrong detection | `CFLAGS` with `-Wno-error=implicit-function-declaration` etc. |
| 8 | **macOS: no `/usr/include` (zlib/iconv)** | `configure: Cannot find libz` | zlib **into `$PREFIX`** + `--with-zlib-dir=$PREFIX` (see also #10) |
| 9 | **ICU dylibs with a bare `install_name`** | `dyld: Library not loaded: libicui18n.66.dylib` | build ICU with `-headerpad_max_install_names` + `install_name_tool` → absolute paths |
| 10 | **`xml2-config --libs` returns `-L$SDK/usr/lib`** | linking `php` fails on `_libiconv*` (picks the system libiconv lacking those symbols) | `xml2-config` shim stripping `-L/-I` to the SDK → our `-L$PREFIX/lib` first |
| 11 | **ext/intl uses `u_sprintf` from icuio** | linking `php` fails on `_u_sprintf_66` | ICU built **with** icuio (not `--disable-icuio`); intl links `-licuio` |
| 12 | **opcache under php-fpm SIGBUSes on macOS arm64** | worker `exited on signal 10 (SIGBUS)`, nginx returns 502 | `opcache.enable=0` in the FPM pool (`etc/php-fpm.d/www.conf`). CLI/APCu work; dev doesn't need opcache |

The trickiest were **#9** and **#11**: ICU writes bare dependency names
(`libicui18n.66.dylib`) into its dylibs that `-rpath` cannot resolve; fixing it
requires `-headerpad_max_install_names` at ICU build time, otherwise
`install_name_tool` has no room for the longer absolute path. Also the ICU
`i18n` stub contains digits — the dependency-rewriting regex must be
`libicu[a-z0-9]*\.[0-9]+\.dylib` (plain `[a-z]*` would miss it).

## Cleaning / rebuilding

```bash
rm -rf ~/php56-build          # sources + intermediate logs (safe)
rm -rf /opt/php56             # the finished build
./compile-php.sh              # from scratch
./compile-php.sh icu php      # selected steps only (idempotent)
```

Per-step logs: `~/php56-build/logs/<step>.log`.

## Distribution

Hand the finished prefix to someone else as one compressed archive:

```bash
./compile-php.sh dist        # → ~/php56-build/dist/php56-php5.6-macos-arm64-<tag>.tar.{zst,xz} (+ .sha256)
```

- **`bsdtar --disable-copyfile`** — no macOS `._*` (AppleDouble) or `copyfile(3)`
  xattrs in the archive.
- **Compression `zstd -19`** (falls back to `xz -9` when `zstd` is absent — CI
  publishes `.tar.xz` because macOS `tar` reads xz natively, no extra tool to
  unpack).
- The archive is **minimal**: build cruft (`include/`, `lib/*.a`,
  `lib/php/build`, `share/{man,doc,aclocal}`, `php/`, `html/`) is **excluded**
  (locally the prefix stays full → you can still add extensions, unlike `slim`).
- **Excluded:** `var/` (runtime), `etc/ssl` (the TLS cert is generated locally
  by `install.sh`; no private key in a public release).

Unpacking on the target machine — it **must** land in `/opt/php56` (the binaries
have absolute `install_name`s); `install.sh` does this for you, or manually:

```bash
sudo mkdir -p /opt/php56 && sudo chown "$(whoami)" /opt/php56
tar -C /opt -xf php56-php5.6-macos-arm64-<tag>.tar.xz      # .xz: native on macOS
# for a .zst archive:  zstd -dc …tar.zst | tar -C /opt -xf -
```
