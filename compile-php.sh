#!/usr/bin/env bash
# =============================================================================
# macOS-php / compile-php.sh — build the toolchain (PHP 5.6 + nginx).
#
# Builds PHP 5.6.40 + nginx natively (arm64, Apple Silicon) into $PREFIX
# (default /opt/php56) on modern macOS, with these extensions:
#   intl, openssl, curl, pdo_mysql, mysqli, mysqlnd, mbstring, zip, bcmath,
#   exif, opcache  (+ APCu and Tideways/XHProf as PECL).
#
# SAPI: CLI (also gives the built-in server: `php -S host:port`) and FPM.
#
# Every non-trivial dependency (OpenSSL 1.1.1, ICU 66, libiconv, zlib, curl)
# is compiled FROM SOURCE into the same prefix with ABSOLUTE install_names,
# and pcre2 is linked statically into nginx, so the result is fully
# self-contained: it needs neither Homebrew nor DYLD_* at runtime. The only
# libraries linked outside the prefix are ones macOS always ships (libSystem,
# libc++, libresolv, libxml2, libicucore).
#
# Usage:
#   ./compile-php.sh                 # full build from scratch (all steps)
#   ./compile-php.sh openssl icu     # only selected steps (see STEPS below)
#   ./compile-php.sh -l              # list steps
#   PREFIX=/tmp/php ./compile-php.sh  # different prefix
#   ./compile-php.sh dist            # pack the prefix into a distribution archive
#   ./compile-php.sh slim            # minimize the prefix (destructive)
# Optional steps (outside the default STEPS): slim, dist.
#
# Steps are mostly idempotent: downloaded archives and built libraries are not
# re-fetched/re-built unless you delete $WORK or $PREFIX.
# =============================================================================
set -euo pipefail

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
source "$HERE/versions.env"

# --- pretty log ---------------------------------------------------------------
c() { printf '\033[1;36m>>> %s\033[0m\n' "$*"; }
ok() { printf '\033[1;32m    ✓ %s\033[0m\n' "$*"; }
die() { printf '\033[1;31m!!! %s\033[0m\n' "$*" >&2; exit 1; }

# Do not build as root — the prefix should be owned by the user (sudo is used
# only to create /opt/php56). root would leave root-owned files behind.
[ "$(id -u)" -eq 0 ] && die "Do not run as root/sudo. Run as a normal user."

run() {  # run <logname> <cmd...> — run and redirect to a log file
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

# SDK/arch flags for the compiler.
SDK="$(xcrun --show-sdk-path)"
ARCHFLAGS="-arch arm64 -mmacosx-version-min=$MACOS_MIN"

# =============================================================================
# build_env — exports the PHP (and PECL) build environment.
# =============================================================================
build_env() {
  # autoconf 2.69 BEFORE brew autoconf; brew bison because the system one is
  # too old; $PREFIX/bin for icu-config / curl-config / phpize.
  export PATH="$AC269_PREFIX/bin:$PREFIX/bin:/opt/homebrew/opt/bison/bin:$PATH"
  export PHP_AUTOCONF="$AC269_PREFIX/bin/autoconf"
  export PHP_AUTOHEADER="$AC269_PREFIX/bin/autoheader"
  export PKG_CONFIG_PATH="$PREFIX/lib/pkgconfig"
  export ICU_CONFIG="$PREFIX/bin/icu-config"

  # Modern clang promotes these legacy-C diagnostics to errors; PHP 5.6 code
  # and configure tests assume the old, lenient behaviour.
  local WNO="-Wno-implicit-function-declaration -Wno-implicit-int \
-Wno-error=implicit-function-declaration -Wno-error=implicit-int \
-Wno-error=int-conversion -Wno-error=incompatible-pointer-types \
-Wno-error=incompatible-function-pointer-types \
-Wno-deprecated-non-prototype -Wno-error=deprecated-non-prototype \
-Wno-error=format-security"
  export CFLAGS="$WNO"
  # ICU 66 no longer injects the `icu` namespace globally → ext/intl needs the
  # define.
  export CXXFLAGS="$WNO -std=c++11 -DU_USING_ICU_NAMESPACE=1"
  export CPPFLAGS="-DU_USING_ICU_NAMESPACE=1 -I$PREFIX/include"
  export LDFLAGS="-L$PREFIX/lib -Wl,-rpath,$PREFIX/lib"
}

# =============================================================================
# fix_install_names — rewrites ICU dylib install_names to ABSOLUTE paths.
# ICU builds with a bare name (e.g. `libicui18n.66.dylib`) that -rpath cannot
# resolve. Requires ICU built with `-headerpad_max_install_names`.
# =============================================================================
fix_install_names() {
  c "fixing ICU install_name → absolute"
  ( cd "$PREFIX/lib"
    for F in libicu*.dylib; do
      if [ -L "$F" ]; then continue; fi          # skip symlinks, real files only
      local id; id="$(otool -D "$F" | sed -n 2p)"
      local leaf; leaf="$(basename "$id")"
      install_name_tool -id "$PREFIX/lib/$leaf" "$F" 2>/dev/null || true
      # NOTE: [a-z0-9]* — the i18n stub has digits; plain [a-z]* would miss it.
      deps="$(otool -L "$F" | awk 'NR>1{print $1}' | grep -E '^libicu[a-z0-9]*\.[0-9]+\.dylib$' || true)"
      for dep in $deps; do
        install_name_tool -change "$dep" "$PREFIX/lib/$dep" "$F" 2>/dev/null || true
      done
    done )
  # verify: none of the libs intl uses (i18n/uc/data/io) may keep a bare dep
  local bad=0 f
  for f in libicui18n libicuuc libicudata libicuio; do
    if otool -L "$PREFIX/lib/$f".*.dylib 2>/dev/null \
        | awk 'NR>1{print $1}' | grep -qE '^libicu'; then
      printf '\033[1;31m    ✗ %s still has bare ICU deps\033[0m\n' "$f"; bad=1
    fi
  done
  [ "$bad" = 0 ] && ok "ICU install_names absolute" || die "fix_install_names did not close ICU"
}

# =============================================================================
# STEPS
# =============================================================================
STEPS=(prereqs autoconf269 confaux openssl icu libiconv zlib curl php pecl nginx config verify)

step_prereqs() {
  # Build-time only: re2c (PHP), autoconf/bison/pkg-config (toolchain). pcre2 is
  # NOT installed via brew — we build it from source into nginx (step_nginx).
  c "Homebrew: re2c, autoconf, bison, pkg-config"
  command -v brew >/dev/null || die "brew not found — install Homebrew"
  brew install re2c autoconf bison pkg-config >/dev/null 2>&1 || \
    brew install re2c autoconf bison pkg-config || true
  mkdir -p "$SRC" "$LOGS"
  # /opt/php56 usually needs sudo to create; then chown to the user.
  # We chown the prefix ITSELF (not its dirname — for /opt/php56 the dirname
  # /opt would also cover homebrew etc).
  if ! ( mkdir -p "$PREFIX" 2>/dev/null && [ -w "$PREFIX" ] ); then
    c "creating $PREFIX (sudo)"
    sudo mkdir -p "$PREFIX"
    sudo chown -R "$(whoami):staff" "$PREFIX"
  fi
  [ -w "$PREFIX" ] || die "$PREFIX is not writable"
  ok "prereqs ready"
}

step_autoconf269() {
  [ -x "$AC269_PREFIX/bin/autoconf" ] && { ok "autoconf $AUTOCONF_LEGACY_VER already present"; return; }
  fetch "https://ftp.gnu.org/gnu/autoconf/autoconf-$AUTOCONF_LEGACY_VER.tar.gz" \
        "autoconf-$AUTOCONF_LEGACY_VER.tar.gz"
  c "building autoconf $AUTOCONF_LEGACY_VER → $AC269_PREFIX"
  ( cd "$SRC" && rm -rf "autoconf-$AUTOCONF_LEGACY_VER.d" && tar xf "autoconf-$AUTOCONF_LEGACY_VER.tar.gz" )
  run "autoconf269" bash -c "cd '$SRC/autoconf-$AUTOCONF_LEGACY_VER' && \
      ./configure --prefix='$AC269_PREFIX' && make -j$JOBS && make install"
  ok "autoconf $AUTOCONF_LEGACY_VER built"
}

step_confaux() {
  # arm64-aware config.sub/config.guess come from a MODERN autoconf (brew).
  # The ones from autoconf 2.69 are from 2012 and don't know arm64-apple-darwin.
  local aux; aux="$(brew --prefix autoconf)/share/autoconf/build-aux"
  [ -f "$aux/config.sub" ] || die "missing $aux/config.sub (install brew autoconf)"
  cp "$aux/config.sub" "$aux/config.guess" "$WORK/"
  chmod +x "$WORK/config.sub" "$WORK/config.guess"
  "$WORK/config.sub" arm64-apple-darwin >/dev/null || die "config.sub does not know arm64"

  # xml2-config shim: the system /usr/bin/xml2-config --libs returns
  # -L$SDK/usr/lib, which PHP puts BEFORE our -L$PREFIX/lib → then -liconv picks
  # the system libiconv (POSIX _iconv*) instead of our GNU one (_libiconv*), and
  # linking php fails on _libiconv/_libiconv_open. The shim strips -L/-I to SDK.
  mkdir -p "$WORK/libxml-shim/bin"
  cat > "$WORK/libxml-shim/bin/xml2-config" <<'EOF'
#!/bin/sh
/usr/bin/xml2-config "$@" | sed -E 's@-L[^ ]*MacOSX\.sdk/usr/lib@@g; s@-I[^ ]*MacOSX\.sdk/usr/include@@g'
EOF
  chmod +x "$WORK/libxml-shim/bin/xml2-config"
  ok "config.sub/guess + xml2-config shim ready"
}

step_openssl() {
  [ -f "$PREFIX/lib/libssl.1.1.dylib" ] && { ok "OpenSSL already built"; return; }
  fetch "https://github.com/openssl/openssl/releases/download/OpenSSL_${OPENSSL_VER//./_}/openssl-$OPENSSL_VER.tar.gz" \
        "openssl-$OPENSSL_VER.tar.gz"
  ( cd "$SRC" && rm -rf "openssl-$OPENSSL_VER" && tar xf "openssl-$OPENSSL_VER.tar.gz" )
  c "building OpenSSL $OPENSSL_VER (darwin64-arm64) → $PREFIX"
  run "openssl" bash -c "cd '$SRC/openssl-$OPENSSL_VER' && \
      ./Configure darwin64-arm64-cc shared no-tests \
        --prefix='$PREFIX' --openssldir='$PREFIX/ssl' -mmacosx-version-min=$MACOS_MIN && \
      make -j$JOBS && make install_sw install_ssldirs"
  ok "OpenSSL $OPENSSL_VER (arm64) installed"
}

step_icu() {
  fetch "https://github.com/unicode-org/icu/releases/download/$ICU_VER_TAG/icu4c-${ICU_VER_FILE}-src.tgz" \
        "icu4c-${ICU_VER_FILE}-src.tgz"
  ( cd "$SRC" && rm -rf icu && tar xf "icu4c-${ICU_VER_FILE}-src.tgz" )
  # arm64-aware config.sub/guess into the ICU tree
  cp "$WORK/config.sub" "$WORK/config.guess" "$SRC/icu/source/"

  # ICU data filter (libicudata is ~27M for full data). ICU_LOCALES (from
  # versions.env) limits data to selected languages; empty = full data.
  # The filter only applies when data is built FROM SOURCE — so we fetch the
  # raw -data.zip, DELETE the prebuilt .dat (forcing a rebuild) and export
  # ICU_DATA_FILTER_FILE.
  local FILTER_EXPORT=""
  if [ -n "${ICU_LOCALES:-}" ]; then
    fetch "https://github.com/unicode-org/icu/releases/download/$ICU_VER_TAG/icu4c-${ICU_VER_FILE}-data.zip" \
          "icu4c-${ICU_VER_FILE}-data.zip"
    command -v unzip >/dev/null || die "missing unzip (needed for raw ICU data)"
    c "raw ICU data (data.zip) → source/data + removing prebuilt .dat"
    ( cd "$SRC/icu/source" && unzip -oq "$SRC/icu4c-${ICU_VER_FILE}-data.zip" && rm -f data/in/*.dat )
    # ICU 66 uses whitelist/blacklist (includelist/excludelist only in 68+).
    local list; list=$(printf '"%s",' $ICU_LOCALES); list="[${list%,}]"
    cat > "$WORK/icu-filter.json" <<JSON
{ "localeFilter": { "filterType": "language", "whitelist": $list } }
JSON
    FILTER_EXPORT="export ICU_DATA_FILTER_FILE='$WORK/icu-filter.json'; "
    c "ICU data filter: languages = $ICU_LOCALES (libicudata trimmed, rebuilt from source)"
  else
    c "ICU data: full (ICU_LOCALES empty)"
  fi

  c "building ICU (-std=c++11, -headerpad_max_install_names) → $PREFIX"
  # headerpad: REQUIRED so install_name_tool can later write the longer,
  # absolute paths (see fix_install_names).
  run "icu" bash -c "cd '$SRC/icu/source' && ${FILTER_EXPORT}\
      CFLAGS='$ARCHFLAGS' CXXFLAGS='$ARCHFLAGS -std=c++11' \
      LDFLAGS='-headerpad_max_install_names' \
      ./runConfigureICU MacOSX --prefix='$PREFIX' \
        --disable-samples --disable-tests --disable-extras --disable-layoutex && \
      make -j$JOBS && make install"
  fix_install_names
  ok "ICU $ICU_VER_FILE (arm64) installed"
}

step_libiconv() {
  [ -f "$PREFIX/lib/libiconv.2.dylib" ] && { ok "libiconv already present"; return; }
  fetch "https://ftp.gnu.org/pub/gnu/libiconv/libiconv-$LIBICONV_VER.tar.gz" \
        "libiconv-$LIBICONV_VER.tar.gz"
  ( cd "$SRC" && rm -rf "libiconv-$LIBICONV_VER" && tar xf "libiconv-$LIBICONV_VER.tar.gz" )
  # The macOS SDK ships only libiconv.tbd (a stub) — PHP needs a real .dylib +
  # the GNU symbols (_libiconv*). Hence our own build into the prefix.
  c "building GNU libiconv $LIBICONV_VER → $PREFIX"
  run "libiconv" bash -c "cd '$SRC/libiconv-$LIBICONV_VER' && \
      ./configure --prefix='$PREFIX' --enable-shared --disable-static CFLAGS='$ARCHFLAGS' && \
      make -j$JOBS && make install"
  ok "libiconv $LIBICONV_VER (arm64) installed"
}

step_zlib() {
  [ -f "$PREFIX/lib/libz.1.dylib" ] && { ok "zlib already present"; return; }
  fetch "https://github.com/madler/zlib/releases/download/v$ZLIB_VER/zlib-$ZLIB_VER.tar.gz" \
        "zlib-$ZLIB_VER.tar.gz"
  ( cd "$SRC" && rm -rf "zlib-$ZLIB_VER" && tar xf "zlib-$ZLIB_VER.tar.gz" )
  # zlib in the prefix ⇒ --with-zlib-dir=$PREFIX ⇒ we don't inject
  # -L$SDK/usr/lib, so the linker picks OUR libiconv (not the system one,
  # which lacks _libiconv*).
  c "building zlib $ZLIB_VER → $PREFIX"
  run "zlib" bash -c "cd '$SRC/zlib-$ZLIB_VER' && \
      CFLAGS='$ARCHFLAGS' ./configure --prefix='$PREFIX' && \
      make -j$JOBS && make install"
  ok "zlib $ZLIB_VER (arm64) installed"
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
  # 1) sources
  if [ ! -d "$SRC/php/.git" ]; then
    c "cloning PHP ($PHP_SRC_REF)"
    run "php-clone" git clone --branch "$PHP_SRC_REF" --depth 1 "$PHP_SRC_REPO" "$SRC/php"
  fi
  # 2) arm64-aware config.sub/guess (configure looks for them in the source dir)
  cp "$WORK/config.sub" "$WORK/config.guess" "$SRC/php/"
  chmod +x "$SRC/php/config.sub" "$SRC/php/config.guess"
  # 3) configure from source (autoconf 2.69!) — force regeneration
  c "buildconf (autoconf $AUTOCONF_LEGACY_VER)"
  ( cd "$SRC/php" && rm -f configure main/php_config.h.in && rm -rf autom4te.cache && \
    run "buildconf" ./buildconf --force )
  # 4) configure with the full extension set + macOS specifics
  c "configure PHP 5.6 (full extension set, CLI + FPM)"
  run "configure" bash -c "cd '$SRC/php' && rm -f config.cache && ./configure \
      --prefix='$PREFIX' \
      --with-config-file-path='$PREFIX/etc/php' \
      --with-config-file-scan-dir='$PREFIX/etc/php/conf.d' \
      --enable-cli \
      --enable-fpm \
      --disable-cgi --disable-phpdbg --disable-phar --without-pear \
      --without-gd --without-ldap --without-mcrypt --without-readline \
      --without-sqlite3 --without-pdo-sqlite \
      --enable-mysqlnd --with-mysqli=mysqlnd --with-pdo-mysql=mysqlnd \
      --with-openssl='$PREFIX' \
      --with-zlib --with-zlib-dir='$PREFIX' \
      --with-iconv='$PREFIX' \
      --with-curl='$PREFIX' \
      --with-libxml-dir='$WORK/libxml-shim' \
      --enable-mbstring --enable-intl --enable-bcmath \
      --enable-zip --enable-exif --enable-opcache \
      --enable-soap=no"
  # 5) make + install
  c "make -j$JOBS (this takes a few minutes)"
  run "make" bash -c "cd '$SRC/php' && make -j$JOBS"
  c "make install → $PREFIX"
  run "make-install" bash -c "cd '$SRC/php' && make install"
  ok "PHP 5.6.40 installed in $PREFIX"
}

step_pecl() {
  build_env
  command -v "$PREFIX/bin/phpize" >/dev/null || die "phpize missing — run step php first"
  # APCu 4.0.x — last branch for PHP 5.6
  if ! ls "$PREFIX"/lib/php/extensions/*/apcu.so >/dev/null 2>&1; then
    [ -d "$SRC/apcu" ] || run "apcu-clone" git clone --depth 1 --branch "v$APCU_VER" \
        https://github.com/krakjoe/apcu.git "$SRC/apcu"
    c "building APCu $APCU_VER"
    run "apcu" bash -c "cd '$SRC/apcu' && '$PREFIX/bin/phpize' && \
        ./configure --with-php-config='$PREFIX/bin/php-config' && make -j$JOBS && make install"
    ok "APCu built"
  else ok "APCu already present"; fi
  # Tideways XHProf-compatible
  if ! ls "$PREFIX"/lib/php/extensions/*/tideways_xhprof.so >/dev/null 2>&1; then
    [ -d "$SRC/tideways" ] || run "tideways-clone" git clone --depth 1 --branch "v$TIDEWAYS_VER" \
        https://github.com/tideways/php-xhprof-extension.git "$SRC/tideways"
    c "building Tideways/XHProf $TIDEWAYS_VER"
    run "tideways" bash -c "cd '$SRC/tideways' && '$PREFIX/bin/phpize' && \
        ./configure --with-php-config='$PREFIX/bin/php-config' && make -j$JOBS && make install"
    ok "Tideways/XHProf built"
  else ok "Tideways already present"; fi
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
  c "building nginx $NGINX_VER (OpenSSL 1.1.1w + static pcre2 $PCRE2_VER) → $PREFIX"
  # NOTE: no --with-file-aio — that is Linux/FreeBSD (ngx_aiocb_t); macOS lacks it.
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
        --with-pcre="$SRC/pcre2-$PCRE2_VER" --with-pcre-jit --with-threads \
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
  # Keep only the files we actually use. The rest are .default + charset maps +
  # scgi/uwsgi params for modules we don't build → remove them.
  # Kept: nginx.conf, mime.types, fastcgi_params.
  ( cd "$PREFIX/etc/nginx" && rm -f ./*.default fastcgi.conf koi-utf koi-win win-utf \
        scgi_params uwsgi_params ) 2>/dev/null || true
  ok "nginx $NGINX_VER (arm64) installed"
}

step_slim() {
  # Optional (NOT in default STEPS) — minimizes the prefix to runtime only.
  # NOTE: removes phpize/php-config/headers → after slim you can NO LONGER build
  # extensions (the `pecl` step). Do this last, when you won't add extensions.
  c "slim: removing build cruft from $PREFIX"
  rm -rf "$PREFIX/include" "$PREFIX"/lib/*.a "$PREFIX/lib/pkgconfig" \
         "$PREFIX/lib/php/build" "$PREFIX/php" \
         "$PREFIX/share/man" "$PREFIX/share/doc" "$PREFIX/share/aclocal" "$PREFIX/html"
  ( cd "$PREFIX/bin" 2>/dev/null && for b in derb genbrk gencfu gencnval gendict genrb \
        icuinfo makeconv pkgdata icu-config curl curl-config wcurl iconv phpize php-config; do
      rm -f "$b"; done ) || true
  ok "slim done — kept php, openssl + runtime (dylibs, .so, php-fpm, nginx)"
}

step_dist() {
  # Optional (NOT in default STEPS) — packs the prefix into a distribution
  # archive. Unlike `slim` it does NOT destroy the prefix: build cruft is only
  # EXCLUDED from the archive (it stays locally → you can still add extensions).
  [ -x "$PREFIX/bin/php" ] || die "missing $PREFIX/bin/php — build first (./compile-php.sh)"
  command -v bsdtar >/dev/null 2>&1 || die "missing bsdtar (macOS /usr/bin/bsdtar)"

  local parent bn outdir base out
  parent="$(dirname "$PREFIX")"; bn="$(basename "$PREFIX")"
  outdir="${DIST_OUT:-$WORK/dist}"; mkdir -p "$outdir"
  # Version stamp: DIST_TAG (e.g. CI tag) or date.
  local tag="${DIST_TAG:-$(date +%Y%m%d)}"
  base="$bn-php5.6-macos-arm64-$tag"

  # Excluded: runtime (var), TLS cert (etc/ssl — generated locally by
  # install.sh; we don't ship a private key in a public Release), build cruft.
  local ex exargs e
  ex="var etc/ssl \
include php html lib/php/build lib/pkgconfig lib/*.a \
share/man share/doc share/aclocal"
  exargs=()
  for e in $ex; do exargs+=( --exclude "$bn/$e" ); done

  # bsdtar --disable-copyfile: no AppleDouble (._*) or copyfile(3) xattrs.
  # Compression via DIST_COMPRESS: xz (default for releases — macOS `tar` reads
  # it natively, no extra tool to unpack) or zstd (smaller/faster, but the end
  # user may need the zstd binary). `auto` prefers zstd if present, else xz.
  local fmt="${DIST_COMPRESS:-xz}"
  [ "$fmt" = auto ] && { command -v zstd >/dev/null 2>&1 && fmt=zstd || fmt=xz; }
  case "$fmt" in
    zstd)
      command -v zstd >/dev/null 2>&1 || die "DIST_COMPRESS=zstd but zstd is missing"
      out="$outdir/$base.tar.zst"
      c "packing $PREFIX → $out  (bsdtar --disable-copyfile | zstd -19 -T0)"
      bsdtar --disable-copyfile "${exargs[@]}" -cf - -C "$parent" "$bn" \
        | zstd -19 -T0 -q -f -o "$out"
      ;;
    xz)
      command -v xz >/dev/null 2>&1 || die "DIST_COMPRESS=xz but xz is missing"
      out="$outdir/$base.tar.xz"
      c "packing $PREFIX → $out  (bsdtar --disable-copyfile | xz -9 -T0)"
      bsdtar --disable-copyfile "${exargs[@]}" -cf - -C "$parent" "$bn" \
        | xz -9 -T0 -c > "$out"
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
  # php.ini + conf.d
  cp "$HERE/etc/php.ini"               "$PREFIX/etc/php/php.ini"
  cp "$HERE/etc/conf.d/10-opcache.ini" "$PREFIX/etc/php/conf.d/10-opcache.ini"
  cp "$HERE/etc/conf.d/15-apcu.ini"    "$PREFIX/etc/php/conf.d/15-apcu.ini"
  cp "$HERE/etc/conf.d/99-perf.ini"    "$PREFIX/etc/php/conf.d/99-perf.ini"
  # FPM pool (Unix socket) — only @PREFIX@ is substituted. We do NOT bake the
  # user: FPM runs non-root as the current user, so the prefix stays portable.
  sed -e "s|@PREFIX@|$PREFIX|g" \
      "$HERE/etc/php-fpm.d/www.conf" > "$PREFIX/etc/php-fpm.d/www.conf"
  # minimal php-fpm.conf
  cat > "$PREFIX/etc/php-fpm.conf" <<EOF
[global]
error_log = $PREFIX/var/log/php-fpm.log
pid = $PREFIX/var/run/php-fpm.pid
daemonize = yes
include = $PREFIX/etc/php-fpm.d/*.conf
EOF
  rm -f "$PREFIX/etc/php-fpm.conf.default" "$PREFIX/etc/php-fpm.d"/*.default

  # Base nginx.conf with default values (server_name localhost, port 8443,
  # docroot $PREFIX/www). install.sh can regenerate it with your own values.
  sed -e "s|@PREFIX@|$PREFIX|g" \
      -e "s|@SERVER_NAME@|localhost|g" \
      -e "s|@PORT@|8443|g" \
      -e "s|@DOCROOT@|$PREFIX/www|g" \
      "$HERE/etc/nginx/nginx.conf.template" > "$PREFIX/etc/nginx/nginx.conf"

  # Starter docroot page (welcome). Plain PHP 5.6.
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
  # nginx -t needs a cert — generate an ephemeral self-signed one (NOT shipped in dist)
  if [ ! -f "$PREFIX/etc/ssl/server.crt" ]; then
    mkdir -p "$PREFIX/etc/ssl"
    "$PREFIX/bin/openssl" req -x509 -newkey rsa:2048 -nodes -days 1 \
      -keyout "$PREFIX/etc/ssl/server.key" -out "$PREFIX/etc/ssl/server.crt" \
      -subj "/CN=localhost" >/dev/null 2>&1 || true
  fi
  echo "--- nginx -t ---"
  "$PREFIX/sbin/nginx" -t -c "$PREFIX/etc/nginx/nginx.conf" 2>&1 || true
  echo "--- key extensions ---"
  "$PREFIX/bin/php" -r 'foreach(["intl","openssl","curl","mysqli","pdo_mysql","mbstring","zip","bcmath","exif","Zend OPcache","apcu"] as $e){printf("  %-14s %s\n",$e,extension_loaded($e)?"OK":"MISSING");}'
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
