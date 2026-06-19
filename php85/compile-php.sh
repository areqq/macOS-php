#!/usr/bin/env bash
# =============================================================================
# macOS-php / php85 / compile-php.sh — build the toolchain (PHP 8.5 + nginx).
#
# Builds PHP 8.5 + nginx natively (arm64, Apple Silicon) into $PREFIX
# (default /opt/php8.5) on modern macOS, with the production extension set:
#   mysqli, pdo_mysql, mysqlnd, mbstring, curl, dom/simplexml/xml*, apcu,
#   opcache (+ JIT)  — intl/zip/bcmath/exif/gd are intentionally excluded.
#
# SAPI: CLI (also gives `php -S host:port`) and FPM.
#
# OpenSSL 3, zlib, libiconv, oniguruma and curl are compiled FROM SOURCE into
# the prefix with ABSOLUTE install_names; pcre2 is linked statically into
# nginx. libxml2 comes from the macOS SDK (always present). The result is
# fully self-contained: no Homebrew or DYLD_* at runtime.
#
# Usage:
#   ./compile-php.sh                 # full build from scratch (all steps)
#   ./compile-php.sh openssl php     # only selected steps (see STEPS below)
#   ./compile-php.sh -l              # list steps
#   PREFIX=/tmp/php ./compile-php.sh
#   ./compile-php.sh dist            # pack a distribution archive
# Optional steps (outside the defaults): slim, dist.
# =============================================================================
set -euo pipefail

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
source "$HERE/versions.env"

c() { printf '\033[1;36m>>> %s\033[0m\n' "$*"; }
ok() { printf '\033[1;32m    ✓ %s\033[0m\n' "$*"; }
die() { printf '\033[1;31m!!! %s\033[0m\n' "$*" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] && die "Do not run as root/sudo. Run as a normal user."

run() {  # run <logname> <cmd...>
  local name="$1"; shift
  mkdir -p "$LOGS"
  if ! "$@" >"$LOGS/$name.log" 2>&1; then
    printf '\033[1;31m!!! step %s failed — see %s\033[0m\n' "$name" "$LOGS/$name.log" >&2
    tail -25 "$LOGS/$name.log" >&2 || true
    exit 1
  fi
}

fetch() {  # fetch <url> <outfile>
  local url="$1" out="$2"
  [ -f "$SRC/$out" ] && { ok "have $out"; return; }
  c "downloading $out"
  curl -fSL --retry 3 -o "$SRC/$out" "$url"
}

SDK="$(xcrun --show-sdk-path)"
ARCHFLAGS="-arch arm64 -mmacosx-version-min=$MACOS_MIN"

# =============================================================================
# build_env — exports the PHP (and PECL) build environment.
# =============================================================================
build_env() {
  export PATH="$PREFIX/bin:/opt/homebrew/opt/bison/bin:$PATH"
  # Our vendored libs expose pkg-config (.pc) files; $WORK/pkgconfig holds the
  # SDK libxml-2.0.pc shim (see step_confaux).
  export PKG_CONFIG_PATH="$PREFIX/lib/pkgconfig:$WORK/pkgconfig"
  export CPPFLAGS="-I$PREFIX/include"
  export LDFLAGS="-L$PREFIX/lib -Wl,-rpath,$PREFIX/lib"
}

# =============================================================================
# STEPS
# =============================================================================
STEPS=(prereqs confaux openssl zlib libiconv onig curl php pecl nginx config verify)

step_prereqs() {
  # Build-time only: re2c (PHP), autoconf/bison/pkg-config (toolchain). pcre2 is
  # built from source into nginx (step_nginx). No ICU — intl is excluded.
  c "Homebrew: re2c, autoconf, bison, pkg-config"
  command -v brew >/dev/null || die "brew not found — install Homebrew"
  brew install re2c autoconf bison pkg-config >/dev/null 2>&1 || \
    brew install re2c autoconf bison pkg-config || true
  mkdir -p "$SRC" "$LOGS"
  if ! ( mkdir -p "$PREFIX" 2>/dev/null && [ -w "$PREFIX" ] ); then
    c "creating $PREFIX (sudo)"
    sudo mkdir -p "$PREFIX"
    sudo chown -R "$(whoami):staff" "$PREFIX"
  fi
  [ -w "$PREFIX" ] || die "$PREFIX is not writable"
  ok "prereqs ready"
}

step_confaux() {
  # PHP 8.x ext/libxml detects libxml ONLY via pkg-config (no xml2-config
  # fallback). macOS has no libxml-2.0.pc, but it ships libxml2 in the SDK and
  # /usr/bin/xml2-config describes it. Generate a pkg-config file pointing at
  # the SDK libxml2 → PHP links the always-present system libxml2 (no brew).
  command -v /usr/bin/xml2-config >/dev/null || die "missing /usr/bin/xml2-config (install Command Line Tools)"
  mkdir -p "$WORK/pkgconfig"
  local ver cflags
  ver="$(/usr/bin/xml2-config --version)"
  cflags="$(/usr/bin/xml2-config --cflags)"
  cat > "$WORK/pkgconfig/libxml-2.0.pc" <<EOF
Name: libxml-2.0
Description: macOS SDK libxml2 (system)
Version: $ver
Cflags: $cflags
Libs: -lxml2
EOF
  ok "libxml-2.0.pc → SDK libxml2 $ver"
}

step_openssl() {
  [ -f "$PREFIX/lib/libssl.3.dylib" ] && { ok "OpenSSL already built"; return; }
  fetch "https://github.com/openssl/openssl/releases/download/openssl-$OPENSSL_VER/openssl-$OPENSSL_VER.tar.gz" \
        "openssl-$OPENSSL_VER.tar.gz"
  ( cd "$SRC" && rm -rf "openssl-$OPENSSL_VER" && tar xf "openssl-$OPENSSL_VER.tar.gz" )
  c "building OpenSSL $OPENSSL_VER (darwin64-arm64) → $PREFIX"
  run "openssl" bash -c "cd '$SRC/openssl-$OPENSSL_VER' && \
      ./Configure darwin64-arm64-cc shared no-tests \
        --prefix='$PREFIX' --openssldir='$PREFIX/ssl' -mmacosx-version-min=$MACOS_MIN && \
      make -j$JOBS && make install_sw install_ssldirs"
  ok "OpenSSL $OPENSSL_VER (arm64) installed"
}

step_zlib() {
  [ -f "$PREFIX/lib/libz.1.dylib" ] && { ok "zlib already present"; return; }
  fetch "https://github.com/madler/zlib/releases/download/v$ZLIB_VER/zlib-$ZLIB_VER.tar.gz" \
        "zlib-$ZLIB_VER.tar.gz"
  ( cd "$SRC" && rm -rf "zlib-$ZLIB_VER" && tar xf "zlib-$ZLIB_VER.tar.gz" )
  c "building zlib $ZLIB_VER → $PREFIX"
  run "zlib" bash -c "cd '$SRC/zlib-$ZLIB_VER' && \
      CFLAGS='$ARCHFLAGS' ./configure --prefix='$PREFIX' && \
      make -j$JOBS && make install"
  ok "zlib $ZLIB_VER (arm64) installed"
}

step_libiconv() {
  [ -f "$PREFIX/lib/libiconv.2.dylib" ] && { ok "libiconv already present"; return; }
  fetch "https://ftp.gnu.org/pub/gnu/libiconv/libiconv-$LIBICONV_VER.tar.gz" \
        "libiconv-$LIBICONV_VER.tar.gz"
  ( cd "$SRC" && rm -rf "libiconv-$LIBICONV_VER" && tar xf "libiconv-$LIBICONV_VER.tar.gz" )
  # The macOS SDK ships only libiconv.tbd (a stub); the iconv extension needs a
  # real .dylib with the GNU symbols. Build our own.
  c "building GNU libiconv $LIBICONV_VER → $PREFIX"
  run "libiconv" bash -c "cd '$SRC/libiconv-$LIBICONV_VER' && \
      ./configure --prefix='$PREFIX' --enable-shared --disable-static CFLAGS='$ARCHFLAGS' && \
      make -j$JOBS && make install"
  ok "libiconv $LIBICONV_VER (arm64) installed"
}

step_onig() {
  [ -f "$PREFIX/lib/libonig.5.dylib" ] && { ok "oniguruma already present"; return; }
  fetch "https://github.com/kkos/oniguruma/releases/download/v$ONIG_VER/onig-$ONIG_VER.tar.gz" \
        "onig-$ONIG_VER.tar.gz"
  ( cd "$SRC" && rm -rf "onig-$ONIG_VER" && tar xf "onig-$ONIG_VER.tar.gz" )
  # PHP 7.4+ unbundled oniguruma; mbstring's mb_ereg* need it. pkg-config file
  # lands in $PREFIX/lib/pkgconfig → PHP's mbstring picks it up.
  c "building oniguruma $ONIG_VER → $PREFIX"
  run "onig" bash -c "cd '$SRC/onig-$ONIG_VER' && \
      ./configure --prefix='$PREFIX' --enable-shared --disable-static CFLAGS='$ARCHFLAGS' && \
      make -j$JOBS && make install"
  ok "oniguruma $ONIG_VER (arm64) installed"
}

step_curl() {
  [ -f "$PREFIX/lib/libcurl.4.dylib" ] && { ok "curl already present"; return; }
  fetch "https://curl.se/download/curl-$CURL_VER.tar.xz" "curl-$CURL_VER.tar.xz"
  ( cd "$SRC" && rm -rf "curl-$CURL_VER" && tar xf "curl-$CURL_VER.tar.xz" )
  c "building curl $CURL_VER (OpenSSL backend) → $PREFIX"
  run "curl" bash -c "cd '$SRC/curl-$CURL_VER' && \
      ./configure --prefix='$PREFIX' --with-openssl='$PREFIX' --with-zlib='$PREFIX' \
        --enable-shared --disable-static \
        --disable-ldap --disable-ldaps --disable-rtsp --disable-dict --disable-file \
        --disable-gopher --disable-imap --disable-mqtt --disable-pop3 --disable-smb \
        --disable-smtp --disable-telnet --disable-tftp --disable-manual --disable-docs \
        --disable-ntlm-wb --without-libpsl --without-libssh --without-libssh2 \
        --without-librtmp --without-libidn2 --without-brotli --without-zstd \
        --without-nghttp2 --without-nghttp3 --without-ngtcp2 --without-quiche \
        --without-gssapi --without-libgsasl && \
      make -j$JOBS && make install"
  ok "curl $CURL_VER (arm64) installed"
}

step_php() {
  build_env
  if [ ! -d "$SRC/php/.git" ]; then
    c "cloning PHP ($PHP_SRC_REF)"
    run "php-clone" git clone --branch "$PHP_SRC_REF" --depth 1 "$PHP_SRC_REPO" "$SRC/php"
  fi
  c "buildconf"
  ( cd "$SRC/php" && run "buildconf" ./buildconf --force )
  c "configure PHP 8.5 (production extension set, CLI + FPM)"
  # libxml/dom/simplexml/xml*/fileinfo are enabled by default; openssl/zlib/
  # curl/oniguruma are found via pkg-config (PKG_CONFIG_PATH from build_env).
  run "configure" bash -c "cd '$SRC/php' && rm -f config.cache && ./configure \
      --prefix='$PREFIX' \
      --with-config-file-path='$PREFIX/etc/php' \
      --with-config-file-scan-dir='$PREFIX/etc/php/conf.d' \
      --enable-cli \
      --enable-fpm \
      --disable-cgi --disable-phpdbg --without-pear \
      --without-sqlite3 --without-pdo-sqlite \
      --enable-mysqlnd --with-mysqli=mysqlnd --with-pdo-mysql=mysqlnd \
      --with-openssl \
      --with-zlib \
      --with-curl \
      --with-iconv='$PREFIX' \
      --enable-mbstring \
      --enable-opcache=shared"
  c "make -j$JOBS (this takes a few minutes)"
  run "make" bash -c "cd '$SRC/php' && make -j$JOBS"
  c "make install → $PREFIX"
  run "make-install" bash -c "cd '$SRC/php' && make install"
  ok "PHP 8.5 installed in $PREFIX"
}

step_pecl() {
  build_env
  command -v "$PREFIX/bin/phpize" >/dev/null || die "phpize missing — run step php first"
  if ! ls "$PREFIX"/lib/php/extensions/*/apcu.so >/dev/null 2>&1; then
    [ -d "$SRC/apcu" ] || run "apcu-clone" git clone --depth 1 --branch "v$APCU_VER" \
        https://github.com/krakjoe/apcu.git "$SRC/apcu"
    c "building APCu $APCU_VER"
    run "apcu" bash -c "cd '$SRC/apcu' && '$PREFIX/bin/phpize' && \
        ./configure --with-php-config='$PREFIX/bin/php-config' && make -j$JOBS && make install"
    ok "APCu built"
  else ok "APCu already present"; fi
}

step_nginx() {
  [ -x "$PREFIX/sbin/nginx" ] && { ok "nginx already built"; return; }
  fetch "https://nginx.org/download/nginx-$NGINX_VER.tar.gz" "nginx-$NGINX_VER.tar.gz"
  ( cd "$SRC" && rm -rf "nginx-$NGINX_VER" && tar xf "nginx-$NGINX_VER.tar.gz" )
  # pcre2 sources — nginx compiles them statically into its binary (no runtime
  # dep on Homebrew). nginx >= 1.21.5 accepts a PCRE2 source dir for --with-pcre.
  fetch "https://github.com/PCRE2Project/pcre2/releases/download/pcre2-$PCRE2_VER/pcre2-$PCRE2_VER.tar.gz" \
        "pcre2-$PCRE2_VER.tar.gz"
  ( cd "$SRC" && rm -rf "pcre2-$PCRE2_VER" && tar xf "pcre2-$PCRE2_VER.tar.gz" )
  c "building nginx $NGINX_VER (OpenSSL $OPENSSL_VER + static pcre2 $PCRE2_VER) → $PREFIX"
  run "nginx" bash -c "cd '$SRC/nginx-$NGINX_VER' && \
      ./configure \
        --prefix='$PREFIX' --sbin-path='$PREFIX/sbin/nginx' \
        --conf-path='$PREFIX/etc/nginx/nginx.conf' \
        --error-log-path='$PREFIX/var/log/nginx/error.log' \
        --http-log-path='$PREFIX/var/log/nginx/access.log' \
        --pid-path='$PREFIX/var/run/nginx.pid' --lock-path='$PREFIX/var/run/nginx.lock' \
        --http-client-body-temp-path='$PREFIX/var/cache/nginx/client_temp' \
        --http-proxy-temp-path='$PREFIX/var/cache/nginx/proxy_temp' \
        --http-fastcgi-temp-path='$PREFIX/var/cache/nginx/fastcgi_temp' \
        --with-pcre='$SRC/pcre2-$PCRE2_VER' --with-pcre-jit --with-threads \
        --with-http_ssl_module --with-http_v2_module --with-http_realip_module \
        --with-http_gzip_static_module --with-http_stub_status_module \
        --without-http_autoindex_module --without-http_ssi_module \
        --without-http_userid_module --without-http_mirror_module \
        --without-http_geo_module --without-http_split_clients_module \
        --without-http_referer_module --without-http_uwsgi_module \
        --without-http_scgi_module --without-http_grpc_module \
        --without-http_memcached_module --without-http_empty_gif_module \
        --without-http_browser_module \
        --with-cc-opt='-I$PREFIX/include -mmacosx-version-min=$MACOS_MIN' \
        --with-ld-opt='-L$PREFIX/lib -Wl,-rpath,$PREFIX/lib' && \
      make -j$JOBS && make install"
  ( cd "$PREFIX/etc/nginx" && rm -f ./*.default fastcgi.conf koi-utf koi-win win-utf \
        scgi_params uwsgi_params ) 2>/dev/null || true
  ok "nginx $NGINX_VER (arm64) installed"
}

step_slim() {
  c "slim: removing build cruft from $PREFIX"
  rm -rf "$PREFIX/include" "$PREFIX"/lib/*.a "$PREFIX/lib/pkgconfig" \
         "$PREFIX/lib/php/build" "$PREFIX/php" \
         "$PREFIX/share/man" "$PREFIX/share/doc" "$PREFIX/html"
  ( cd "$PREFIX/bin" 2>/dev/null && for b in curl curl-config wcurl iconv phpize php-config \
        openssl c_rehash onig-config; do rm -f "$b"; done ) || true
  ok "slim done"
}

step_dist() {
  [ -x "$PREFIX/bin/php" ] || die "missing $PREFIX/bin/php — build first (./compile-php.sh)"
  command -v bsdtar >/dev/null 2>&1 || die "missing bsdtar (macOS /usr/bin/bsdtar)"

  local parent bn outdir base out
  parent="$(dirname "$PREFIX")"; bn="$(basename "$PREFIX")"
  outdir="${DIST_OUT:-$WORK/dist}"; mkdir -p "$outdir"
  local tag="${DIST_TAG:-$(date +%Y%m%d)}"
  # bn is already "php8.5" → "php8.5-macos-arm64-<tag>"
  base="$bn-macos-arm64-$tag"

  local ex exargs e
  ex="var etc/ssl \
include php html lib/php/build lib/pkgconfig lib/*.a \
share/man share/doc share/aclocal"
  exargs=()
  for e in $ex; do exargs+=( --exclude "$bn/$e" ); done

  # DIST_COMPRESS: xz (default, macOS tar reads it natively) | zstd | auto.
  local fmt="${DIST_COMPRESS:-xz}"
  [ "$fmt" = auto ] && { command -v zstd >/dev/null 2>&1 && fmt=zstd || fmt=xz; }
  case "$fmt" in
    zstd)
      command -v zstd >/dev/null 2>&1 || die "DIST_COMPRESS=zstd but zstd is missing"
      out="$outdir/$base.tar.zst"
      c "packing $PREFIX → $out  (bsdtar --disable-copyfile | zstd -19 -T0)"
      bsdtar --disable-copyfile "${exargs[@]}" -cf - -C "$parent" "$bn" | zstd -19 -T0 -q -f -o "$out"
      ;;
    xz)
      command -v xz >/dev/null 2>&1 || die "DIST_COMPRESS=xz but xz is missing"
      out="$outdir/$base.tar.xz"
      c "packing $PREFIX → $out  (bsdtar --disable-copyfile | xz -9 -T0)"
      bsdtar --disable-copyfile "${exargs[@]}" -cf - -C "$parent" "$bn" | xz -9 -T0 -c > "$out"
      ;;
    *) die "unknown DIST_COMPRESS=$fmt (use xz | zstd | auto)" ;;
  esac

  ( cd "$outdir" && shasum -a 256 "$(basename "$out")" > "$(basename "$out").sha256" )
  ok "archive: $out  ($(du -h "$out" | cut -f1)), sha256 alongside"
  echo "    EXCLUDED: var/, etc/ssl (cert generated locally), build cruft."
  echo "    The bundle MUST go to $PREFIX (absolute install_names). install.sh does that."
}

step_config() {
  c "installing ini + php-fpm + nginx.conf files (from $HERE/etc)"
  mkdir -p "$PREFIX/etc/php/conf.d" "$PREFIX/etc/php-fpm.d" \
           "$PREFIX/etc/nginx" "$PREFIX/var/run" "$PREFIX/var/log/nginx" \
           "$PREFIX/var/cache/nginx" "$PREFIX/www"
  local extdir; extdir="$("$PREFIX/bin/php-config" --extension-dir)"
  cp "$HERE/etc/php.ini"               "$PREFIX/etc/php/php.ini"
  cp "$HERE/etc/conf.d/10-opcache.ini" "$PREFIX/etc/php/conf.d/10-opcache.ini"
  cp "$HERE/etc/conf.d/15-apcu.ini"    "$PREFIX/etc/php/conf.d/15-apcu.ini"
  cp "$HERE/etc/conf.d/99-perf.ini"    "$PREFIX/etc/php/conf.d/99-perf.ini"
  sed -e "s|@PREFIX@|$PREFIX|g" \
      "$HERE/etc/php-fpm.d/www.conf" > "$PREFIX/etc/php-fpm.d/www.conf"
  cat > "$PREFIX/etc/php-fpm.conf" <<EOF
[global]
error_log = $PREFIX/var/log/php-fpm.log
pid = $PREFIX/var/run/php-fpm.pid
daemonize = yes
include = $PREFIX/etc/php-fpm.d/*.conf
EOF
  rm -f "$PREFIX/etc/php-fpm.conf.default" "$PREFIX/etc/php-fpm.d"/*.default

  sed -e "s|@PREFIX@|$PREFIX|g" \
      -e "s|@SERVER_NAME@|localhost|g" \
      -e "s|@PORT@|8543|g" \
      -e "s|@DOCROOT@|$PREFIX/www|g" \
      "$HERE/etc/nginx/nginx.conf.template" > "$PREFIX/etc/nginx/nginx.conf"

  cat > "$PREFIX/www/index.php" <<'PHPEOF'
<?php
header('Content-Type: text/plain; charset=utf-8');
echo "macOS-php — PHP ", PHP_VERSION, " (", PHP_OS, "/", php_uname('m'), ") is running.\n";
echo "Extensions: ", implode(', ', get_loaded_extensions()), "\n";
PHPEOF
  ok "configuration installed (extension_dir=$extdir)"
}

step_verify() {
  c "verification"
  "$PREFIX/bin/php" -v
  echo "--- modules ---"
  "$PREFIX/bin/php" -m | tr '\n' ' '; echo
  echo "--- php linkage (otool -L) ---"
  otool -L "$PREFIX/bin/php" | sed -n '2,40p'
  echo "--- built-in HTTP server (php -S) smoke test ---"
  local doc; doc="$(mktemp -d)"; echo "<?php echo 'OK ',PHP_VERSION;" > "$doc/index.php"
  "$PREFIX/bin/php" -S 127.0.0.1:8769 -t "$doc" >/dev/null 2>&1 &
  local pid=$!; sleep 1
  local out; out="$(curl -s http://127.0.0.1:8769/ || true)"
  kill "$pid" 2>/dev/null || true; rm -rf "$doc"
  echo "  response: $out"
  echo "--- php-fpm -t ---"
  "$PREFIX/sbin/php-fpm" -t -y "$PREFIX/etc/php-fpm.conf" 2>&1 || true
  if [ ! -f "$PREFIX/etc/ssl/server.crt" ]; then
    mkdir -p "$PREFIX/etc/ssl"
    "$PREFIX/bin/openssl" req -x509 -newkey rsa:2048 -nodes -days 1 \
      -keyout "$PREFIX/etc/ssl/server.key" -out "$PREFIX/etc/ssl/server.crt" \
      -subj "/CN=localhost" >/dev/null 2>&1 || true
  fi
  echo "--- nginx -t ---"
  "$PREFIX/sbin/nginx" -t -c "$PREFIX/etc/nginx/nginx.conf" 2>&1 || true
  echo "--- nginx linkage (otool -L; must show NO Homebrew/pcre2 dylib) ---"
  otool -L "$PREFIX/sbin/nginx" | sed -n '2,40p'
  echo "--- key extensions ---"
  "$PREFIX/bin/php" -r 'foreach(["openssl","curl","mysqli","pdo_mysql","mbstring","dom","SimpleXML","xml","iconv","Zend OPcache","apcu"] as $e){printf("  %-14s %s\n",$e,extension_loaded($e)?"OK":"MISSING");}'
  echo "--- opcache JIT ---"
  "$PREFIX/bin/php" -d opcache.enable_cli=1 -d opcache.jit=1255 -d opcache.jit_buffer_size=64M \
    -r 'echo "  jit_buffer=",ini_get("opcache.jit_buffer_size"),"  ",(function_exists("opcache_get_status")?(($s=opcache_get_status(false))&&!empty($s["jit"]["enabled"])?"JIT enabled":"JIT off"):"no opcache"),"\n";' 2>&1 || true
  ok "verification done"
}

# =============================================================================
# main
# =============================================================================
[ "${1:-}" = "-l" ] && { printf 'Steps: %s\nOptional (outside defaults): slim dist\n' "${STEPS[*]}"; exit 0; }
todo=("$@"); [ ${#todo[@]} -eq 0 ] && todo=("${STEPS[@]}")
mkdir -p "$SRC" "$LOGS"
for s in "${todo[@]}"; do
  type "step_$s" >/dev/null 2>&1 || die "unknown step: $s (see ./compile-php.sh -l)"
  "step_$s"
done
c "DONE. PHP: $PREFIX/bin/php   |   FPM: $PREFIX/sbin/php-fpm   |   nginx: $PREFIX/sbin/nginx"
echo "Add to PATH:  export PATH=\"$PREFIX/bin:\$PATH\""
