#!/usr/bin/env bash
# =============================================================================
# macOS-php / install.sh — install prebuilt PHP 5.6 + nginx from GitHub
# Releases (no local compilation).
#
# It downloads the release bundle, verifies its SHA-256, extracts it to the
# prefix it was built for, then generates the machine-local bits: a self-signed
# TLS certificate and an nginx.conf for your document root.
#
# Usage:
#   ./install.sh                       # latest release
#   ./install.sh v1.2.3                # a specific tag
#   SERVER_NAME=php.local PORT=8443 DOCROOT=/path/to/site ./install.sh
#   MACOS_PHP_URL=https://.../bundle.tar.zst ./install.sh   # explicit bundle URL
#
# Requirements: macOS arm64 (Apple Silicon), curl, tar. No Homebrew needed —
# the bundle is fully self-contained. macOS tar reads the .xz bundle natively.
# =============================================================================
set -euo pipefail

REPO="${REPO:-areqq/macOS-php}"
# Prefix is baked into the binaries (absolute install_names). It MUST match the
# value used at build time. Do not change unless you also rebuilt.
PREFIX="${PREFIX:-/opt/php56}"
SERVER_NAME="${SERVER_NAME:-localhost}"
PORT="${PORT:-8443}"
DOCROOT="${DOCROOT:-$PREFIX/www}"
TAG="${1:-}"

c()   { printf '\033[1;36m>>> %s\033[0m\n' "$*"; }
ok()  { printf '\033[1;32m    ✓ %s\033[0m\n' "$*"; }
die() { printf '\033[1;31m!!! %s\033[0m\n' "$*" >&2; exit 1; }

[ "$(uname -s)" = "Darwin" ] || die "This installer is for macOS only."
[ "$(uname -m)" = "arm64" ]  || die "This bundle is arm64 (Apple Silicon) only."
command -v curl >/dev/null   || die "curl is required."

# --- locate the bundle --------------------------------------------------------
resolve_url() {
  if [ -n "${MACOS_PHP_URL:-}" ]; then echo "$MACOS_PHP_URL"; return; fi
  local api
  if [ -n "$TAG" ]; then
    api="https://api.github.com/repos/$REPO/releases/tags/$TAG"
  else
    api="https://api.github.com/repos/$REPO/releases/latest"
  fi
  c "querying $api" >&2
  curl -fsSL "$api" \
    | grep -oE '"browser_download_url"[ ]*:[ ]*"[^"]*\.tar\.(zst|xz)"' \
    | sed -E 's/.*"(https?:[^"]*)"/\1/' \
    | head -1
}

URL="$(resolve_url)"
[ -n "$URL" ] || die "Could not find a .tar.zst/.tar.xz asset in the release."
ASSET="$(basename "$URL")"
c "bundle: $ASSET"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

c "downloading bundle"
curl -fSL --retry 3 -o "$TMP/$ASSET" "$URL"
# checksum (optional but expected): <asset>.sha256 next to it
if curl -fsSL -o "$TMP/$ASSET.sha256" "$URL.sha256" 2>/dev/null; then
  c "verifying SHA-256"
  ( cd "$TMP" && shasum -a 256 -c "$ASSET.sha256" ) || die "checksum mismatch"
  ok "checksum OK"
else
  printf '\033[1;33m    ! no .sha256 published — skipping checksum\033[0m\n'
fi

# --- create + own the prefix --------------------------------------------------
if ! ( mkdir -p "$PREFIX" 2>/dev/null && [ -w "$PREFIX" ] ); then
  c "creating $PREFIX (sudo)"
  sudo mkdir -p "$PREFIX"
  sudo chown -R "$(whoami):staff" "$PREFIX"
fi
[ -w "$PREFIX" ] || die "$PREFIX is not writable"

c "extracting → $PREFIX"
# Bundle's top dir = basename of PREFIX. macOS tar reads .xz natively; for .zst
# we pipe through the zstd binary if tar can't handle it.
case "$ASSET" in
  *.tar.zst)
    if tar -xf "$TMP/$ASSET" -C "$(dirname "$PREFIX")" 2>/dev/null; then :;
    elif command -v zstd >/dev/null; then
      zstd -dc "$TMP/$ASSET" | tar -x -C "$(dirname "$PREFIX")"
    else
      die "this tar can't read .zst — run: brew install zstd"
    fi
    ;;
  *)
    tar -xf "$TMP/$ASSET" -C "$(dirname "$PREFIX")"
    ;;
esac
[ -x "$PREFIX/bin/php" ] || die "extraction failed: no $PREFIX/bin/php"
ok "binaries installed"

# --- runtime dirs -------------------------------------------------------------
mkdir -p "$PREFIX/var/run" "$PREFIX/var/log/nginx" "$PREFIX/var/cache/nginx" \
         "$PREFIX/etc/ssl" "$DOCROOT"

# --- self-signed TLS cert (local) --------------------------------------------
if [ ! -f "$PREFIX/etc/ssl/server.crt" ] || [ -n "${FORCE_CERT:-}" ]; then
  c "generating self-signed cert for $SERVER_NAME"
  "$PREFIX/bin/openssl" req -x509 -newkey rsa:2048 -nodes -days 825 \
    -keyout "$PREFIX/etc/ssl/server.key" -out "$PREFIX/etc/ssl/server.crt" \
    -subj "/CN=$SERVER_NAME" \
    -addext "subjectAltName=DNS:$SERVER_NAME,DNS:localhost,IP:127.0.0.1" \
    >/dev/null 2>&1 \
    || "$PREFIX/bin/openssl" req -x509 -newkey rsa:2048 -nodes -days 825 \
         -keyout "$PREFIX/etc/ssl/server.key" -out "$PREFIX/etc/ssl/server.crt" \
         -subj "/CN=$SERVER_NAME" >/dev/null 2>&1
  ok "cert ready"
else
  ok "cert already present (FORCE_CERT=1 to regenerate)"
fi

# --- render nginx.conf for the chosen docroot --------------------------------
if [ -f "$PREFIX/etc/nginx/nginx.conf.template" ]; then
  TEMPLATE="$PREFIX/etc/nginx/nginx.conf.template"
else
  # template not shipped in the bundle — regenerate from the installed conf is
  # not possible, so write a minimal one inline.
  TEMPLATE="$TMP/nginx.conf.template"
  cat > "$TEMPLATE" <<'NGINX'
worker_processes  auto;
pid               @PREFIX@/var/run/nginx.pid;
error_log         @PREFIX@/var/log/nginx/error.log;
events { worker_connections 1024; }
http {
    include       @PREFIX@/etc/nginx/mime.types;
    default_type  application/octet-stream;
    access_log    @PREFIX@/var/log/nginx/access.log;
    sendfile on; keepalive_timeout 65; server_tokens off; client_max_body_size 64m;
    server {
        listen @PORT@ ssl; http2 on; server_name @SERVER_NAME@;
        ssl_certificate     @PREFIX@/etc/ssl/server.crt;
        ssl_certificate_key @PREFIX@/etc/ssl/server.key;
        ssl_protocols TLSv1.2 TLSv1.3;
        root @DOCROOT@; index index.php index.html;
        location / { try_files $uri $uri/ /index.php$is_args$args; }
        location ~ \.php$ {
            include @PREFIX@/etc/nginx/fastcgi_params;
            fastcgi_pass unix:@PREFIX@/var/run/php-fpm.sock;
            fastcgi_param SCRIPT_FILENAME $document_root$fastcgi_script_name;
            fastcgi_param HTTPS on;
        }
    }
}
NGINX
fi
c "rendering nginx.conf (server_name=$SERVER_NAME port=$PORT docroot=$DOCROOT)"
sed -e "s|@PREFIX@|$PREFIX|g" \
    -e "s|@SERVER_NAME@|$SERVER_NAME|g" \
    -e "s|@PORT@|$PORT|g" \
    -e "s|@DOCROOT@|$DOCROOT|g" \
    "$TEMPLATE" > "$PREFIX/etc/nginx/nginx.conf"

# starter index if docroot is empty
if [ ! -e "$DOCROOT/index.php" ] && [ ! -e "$DOCROOT/index.html" ]; then
  cat > "$DOCROOT/index.php" <<'PHPEOF'
<?php
header('Content-Type: text/plain; charset=utf-8');
echo "macOS-php — PHP ", PHP_VERSION, " is running.\n";
PHPEOF
fi

# --- start/stop helpers -------------------------------------------------------
cat > "$PREFIX/start.sh" <<EOF
#!/usr/bin/env bash
set -e
"$PREFIX/sbin/php-fpm" -y "$PREFIX/etc/php-fpm.conf"
"$PREFIX/sbin/nginx" -c "$PREFIX/etc/nginx/nginx.conf"
echo "up: https://$SERVER_NAME:$PORT/"
EOF
cat > "$PREFIX/stop.sh" <<EOF
#!/usr/bin/env bash
"$PREFIX/sbin/nginx" -c "$PREFIX/etc/nginx/nginx.conf" -s quit 2>/dev/null || true
[ -f "$PREFIX/var/run/php-fpm.pid" ] && kill "\$(cat "$PREFIX/var/run/php-fpm.pid")" 2>/dev/null || true
echo "stopped"
EOF
chmod +x "$PREFIX/start.sh" "$PREFIX/stop.sh"

c "verifying"
"$PREFIX/bin/php" -v | head -1
"$PREFIX/sbin/nginx" -t -c "$PREFIX/etc/nginx/nginx.conf" 2>&1 | tail -2 || true

cat <<EOF

$(ok "done")
PHP:   $PREFIX/bin/php
nginx: $PREFIX/sbin/nginx
start: $PREFIX/start.sh     (https://$SERVER_NAME:$PORT/)
stop:  $PREFIX/stop.sh

PATH:  export PATH="$PREFIX/bin:\$PATH"
$( [ "$SERVER_NAME" != "localhost" ] && echo "hosts: echo '127.0.0.1 $SERVER_NAME' | sudo tee -a /etc/hosts" )
EOF
