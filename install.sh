#!/usr/bin/env bash
#
# Installs Pixelfed (PHP 8.5.12 + Apache, Horizon, scheduler, MariaDB, Redis in Docker):
#   1. creates .env from .env.dist (random passwords) and asks for domain, port, version
#   2. clones Pixelfed (PIXELFED_REPO, newest release) into the web root (APACHE_HTDOCS)
#   3. writes Pixelfed's own .env (asks for title, registration, federation, mail)
#   4. builds and starts the containers, installs the dependencies, migrates the database
#   5. creates the administrator
#
# On a server it runs as root from /opt/pixelfed/<domain> (sudo ./install.sh): root owns
# this directory and Docker, www-data owns the web root /var/www/htdocs/<domain>.
# Once installed, running it again only (re)starts the containers; updates: ./update.sh
#
# Usage: ./install.sh [-y] [-d DOMAIN] [-p PORT]
#   -y          non-interactive, accept defaults (administrator password is generated)
#   -d DOMAIN   public domain of the instance (default localhost)
#   -p PORT     host port of the web server (default 8080)
#
set -euo pipefail
cd "$(dirname "$0")"
source lib/common.sh

ASSUME_YES=false
OPT_DOMAIN=""
OPT_PORT=""
while getopts "yd:p:h" opt; do
    case "$opt" in
        y) ASSUME_YES=true ;;
        d) OPT_DOMAIN="$OPTARG" ;;
        p) OPT_PORT="$OPTARG" ;;
        *) sed -n '2,19p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    esac
done

INTERACTIVE=true
{ $ASSUME_YES || [ ! -t 0 ]; } && INTERACTIVE=false

# ask VAR QUESTION [DEFAULT]
ask() {
    local answer=""
    $INTERACTIVE && read -r -p "$2${3:+ [$3]}: " answer
    printf -v "$1" '%s' "${answer:-${3:-}}"
}
# ask_yn VAR QUESTION y|n – sets VAR to true/false
ask_yn() {
    local answer=""
    $INTERACTIVE && read -r -p "$2 [$([ "$3" = y ] && echo Y/n || echo y/N)]: " answer
    case "${answer:-$3}" in [yYjJ]*) printf -v "$1" true ;; *) printf -v "$1" false ;; esac
}
# ask_secret VAR QUESTION – hidden input, empty when non-interactive
ask_secret() {
    local answer=""
    if $INTERACTIVE; then read -r -s -p "$2: " answer; echo; fi
    printf -v "$1" '%s' "$answer"
}

# --- requirements --------------------------------------------------------------
require_docker
command -v git >/dev/null 2>&1 || fail "git is required."
if $AS_ROOT; then
    id www-data >/dev/null 2>&1 || fail "User www-data does not exist."
    command -v sudo >/dev/null 2>&1 || fail "sudo is required (to run git as www-data)."
fi

# --- .env ------------------------------------------------------------------------
if [ ! -f .env ]; then
    say "Creating .env"
    cp .env.dist .env
fi
chmod 600 .env    # passwords: only for the owner of this directory (root on a server)

if [ -f .installed ]; then
    resolve_htdocs
    say "Pixelfed is already installed ($(cat .installed)) – starting the containers …"
    compose up -d --build
    say "Done: $(env_get "$HTDOCS/.env" APP_URL | tr -d "'\"")/   ·   updates: $($AS_ROOT && echo sudo) $PWD/update.sh"
    exit 0
fi

say "Docker setup"
DOMAIN=${OPT_DOMAIN:-$(env_get .env APP_DOMAIN)}
while true; do
    ask DOMAIN "Domain of the instance (localhost for local use)" "${DOMAIN:-localhost}"
    DOMAIN=$(printf %s "$DOMAIN" | tr '[:upper:]' '[:lower:]')
    if [ "$DOMAIN" = localhost ] && $AS_ROOT; then
        $INTERACTIVE || fail "Running as root: the domain is required (-d DOMAIN)."
        warn "Running as root (server): please enter the real domain."
        continue
    fi
    [[ "$DOMAIN" =~ ^[a-z0-9.-]+$ ]] && break
    $INTERACTIVE || fail "Invalid domain: $DOMAIN"
    warn "Letters, digits, dots and dashes only."
done
env_set .env APP_DOMAIN "$DOMAIN"
[ "$DOMAIN" = localhost ] || env_set .env APP_NAME "$(printf %s "$DOMAIN" | tr -c 'a-z0-9\n' '-')"

PORT=${OPT_PORT:-$(env_get .env APACHE_PORT)}
ask PORT "Port of the web server on this host (unique per instance)" "${PORT:-8080}"
env_set .env APACHE_PORT "$PORT"

if $AS_ROOT; then
    current=$(env_get .env APACHE_HTDOCS)
    case "$current" in /*) ;; *) current="/var/www/htdocs/$DOMAIN" ;; esac
    ask answer "Pixelfed directory (web root, belongs to www-data)" "$current"
    env_set .env APACHE_HTDOCS "$answer"
fi
resolve_htdocs

ask answer "Pixelfed version (latest = newest release, dev, or a tag like v0.15.2)" "$(env_get .env PIXELFED_VERSION)"
env_set .env PIXELFED_VERSION "${answer:-latest}"
[ -n "$(env_get .env PIXELFED_REPO)" ] || env_set .env PIXELFED_REPO "$(env_get .env.dist PIXELFED_REPO)"
resolve_version

[ -n "$(env_get .env MYSQL_PASSWORD)" ]      || env_set .env MYSQL_PASSWORD "$(random 24)"
[ -n "$(env_get .env MYSQL_ROOT_PASSWORD)" ] || env_set .env MYSQL_ROOT_PASSWORD "$(random 32)"

# --- Pixelfed code -----------------------------------------------------------------
REPO=$(env_get .env PIXELFED_REPO)
if [ ! -d "$HTDOCS/.git" ]; then
    if [ -d "$HTDOCS" ] && [ -n "$(ls -A "$HTDOCS")" ]; then
        fail "$HTDOCS is not empty and no git checkout – move its content away first."
    fi
    say "Cloning Pixelfed ($REPO) into $HTDOCS$($AS_ROOT && echo ' as www-data' || true) …"
    if $AS_ROOT; then
        mkdir -p "$(dirname "$HTDOCS")"
        install -d -o www-data -g www-data "$HTDOCS"
    else
        mkdir -p "$HTDOCS"
    fi
    web git clone -q "$REPO" "$HTDOCS" || fail "Cannot clone $REPO."
fi
check_htdocs_owner
fetch_ref
checkout_ref
say "Pixelfed $REF ($(web git -C "$HTDOCS" rev-parse --short HEAD))"

# --- Pixelfed configuration --------------------------------------------------------
echo
say "Pixelfed configuration"
ask TITLE "Name of the instance (shown on the website)" "Pixelfed"
if [ "$DOMAIN" = localhost ]; then
    URL="http://localhost:$PORT"
else
    ask_yn HTTPS "Served via HTTPS (reverse proxy with certificate)?" y
    $HTTPS && URL="https://$DOMAIN" || URL="http://$DOMAIN"
fi
ask_yn OPEN_REGISTRATION "Open registration (anyone can sign up)?" n
ask_yn VERIFY_EMAIL "Require e-mail verification for new accounts?" "$($OPEN_REGISTRATION && echo y || echo n)"
ask_yn FEDERATION "Federation with the Fediverse (ActivityPub)?" "$([ "$DOMAIN" = localhost ] && echo n || echo y)"
ask_yn CITIES "Import the city database for locations (takes a few minutes)?" y

ask_yn SMTP "Send e-mails via SMTP (otherwise they are only logged)?" n
# Pixelfed rejects addresses without a dot in the domain (…@localhost)
MAIL_DOMAIN=$DOMAIN
[ "$DOMAIN" = localhost ] && MAIL_DOMAIN=example.com
MAIL_FROM="pixelfed@$MAIL_DOMAIN"
if $SMTP; then
    ask MAIL_HOST "SMTP server" ""
    ask MAIL_PORT "SMTP port" 587
    ask MAIL_ENCRYPTION "Encryption (tls, ssl or none)" tls
    ask MAIL_USER "SMTP user" ""
    ask_secret MAIL_PASS "SMTP password"
    ask MAIL_FROM "Sender address" "$MAIL_FROM"
fi

echo
say "Administrator"
ask ADMIN_USER "Username" "admin"
while true; do
    ask ADMIN_EMAIL "E-mail address" "$($INTERACTIVE || echo "admin@$MAIL_DOMAIN")"
    [[ "$ADMIN_EMAIL" =~ ^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$ ]] && break
    $INTERACTIVE || fail "Invalid e-mail address: $ADMIN_EMAIL"
    warn "Please enter a valid e-mail address."
done
while true; do
    ask_secret ADMIN_PASS "Password (empty = generate one)"
    [ -z "$ADMIN_PASS" ] && { ADMIN_PASS=$(random 20); GENERATED_PASS=true; break; }
    [ "${#ADMIN_PASS}" -ge 8 ] || { warn "At least 8 characters."; continue; }
    ask_secret confirm "Repeat password"
    [ "$ADMIN_PASS" = "$confirm" ] && break
    warn "The passwords do not match."
done

# Pixelfed's .env, from its .env.example (belongs to www-data, holds the DB password)
q() { dotenv_quote "$1"; }
tmp=$(mktemp)
cat "$HTDOCS/.env.example" > "$tmp"
env_set "$tmp" APP_NAME "$(q "$TITLE")"
env_set "$tmp" APP_ENV "'production'"
env_set "$tmp" APP_DEBUG "'false'"
env_set "$tmp" APP_KEY ""
env_set "$tmp" APP_URL "$(q "$URL")"
env_set "$tmp" APP_DOMAIN "$(q "$DOMAIN")"
env_set "$tmp" ADMIN_DOMAIN "$(q "$DOMAIN")"
env_set "$tmp" TRUST_PROXIES "'*'"
env_set "$tmp" OPEN_REGISTRATION "'$OPEN_REGISTRATION'"
env_set "$tmp" ENFORCE_EMAIL_VERIFICATION "'$VERIFY_EMAIL'"
env_set "$tmp" INSTANCE_CONTACT_EMAIL "$(q "$ADMIN_EMAIL")"
env_set "$tmp" IMAGE_DRIVER "'vips'"
env_set "$tmp" DB_CONNECTION "'mysql'"
env_set "$tmp" DB_HOST "'db'"
env_set "$tmp" DB_PORT "'3306'"
env_set "$tmp" DB_DATABASE "$(q "$(env_get .env MYSQL_DATABASE)")"
env_set "$tmp" DB_USERNAME "$(q "$(env_get .env MYSQL_USER)")"
env_set "$tmp" DB_PASSWORD "$(q "$(env_get .env MYSQL_PASSWORD)")"
env_set "$tmp" REDIS_HOST "'redis'"
env_set "$tmp" REDIS_PORT "'6379'"
for key in ACTIVITY_PUB AP_REMOTE_FOLLOW AP_INBOX AP_OUTBOX AP_SHAREDINBOX; do
    env_set "$tmp" "$key" "'$FEDERATION'"
done
if $SMTP; then
    env_set "$tmp" MAIL_DRIVER "'smtp'"
    env_set "$tmp" MAIL_HOST "$(q "$MAIL_HOST")"
    env_set "$tmp" MAIL_PORT "$(q "$MAIL_PORT")"
    env_set "$tmp" MAIL_USERNAME "$(q "$MAIL_USER")"
    env_set "$tmp" MAIL_PASSWORD "$(q "$MAIL_PASS")"
    env_set "$tmp" MAIL_ENCRYPTION "$([ "$MAIL_ENCRYPTION" = none ] && echo "'null'" || q "$MAIL_ENCRYPTION")"
else
    env_set "$tmp" MAIL_DRIVER "'log'"
fi
env_set "$tmp" MAIL_FROM_ADDRESS "$(q "$MAIL_FROM")"
env_set "$tmp" MAIL_FROM_NAME "$(q "$TITLE")"
if $AS_ROOT; then
    install -m 600 -o www-data -g www-data "$tmp" "$HTDOCS/.env"
else
    install -m 644 "$tmp" "$HTDOCS/.env"
fi
rm -f "$tmp"

# --- containers and setup ----------------------------------------------------------
echo
say "Building and starting the containers (first run takes a few minutes) …"
compose up -d --build --wait db redis web

say "Installing the dependencies (composer) …"
composer_install
artisan key:generate --force
say "Setting up the database …"
finish_app
artisan instance:actor
artisan passport:keys --force
if $CITIES; then
    say "Importing the city database …"
    artisan import:cities
fi

say "Creating the administrator $ADMIN_USER …"
artisan user:create --name="$ADMIN_USER" --username="$ADMIN_USER" --email="$ADMIN_EMAIL" \
    --password="$ADMIN_PASS" --is_admin=true --confirm_email=1

say "Starting Horizon (queue) and the scheduler …"
compose up -d

echo "$REF, $(date '+%Y-%m-%d %H:%M')" > .installed

# --- host nginx --------------------------------------------------------------------
NGINX_CONF="nginx/$DOMAIN.conf"
if [ "$DOMAIN" != localhost ]; then
    mkdir -p nginx
    cat > "$NGINX_CONF" <<EOF
# Host nginx configuration for $DOMAIN – generated by install.sh
#
#   sudo cp $PWD/$NGINX_CONF /etc/nginx/sites-available/$DOMAIN
#   sudo ln -s /etc/nginx/sites-available/$DOMAIN /etc/nginx/sites-enabled/
#   sudo nginx -t && sudo systemctl reload nginx
#   sudo certbot --nginx -d $DOMAIN

server {
    listen 80;
    listen [::]:80;

    server_name $DOMAIN;

    # Must be >= post_max_size in config/php/php.ini
    client_max_body_size 100M;

    location / {
        proxy_pass http://127.0.0.1:$PORT;

        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;

        proxy_read_timeout 120s;
        proxy_send_timeout 120s;
    }
}
EOF
fi

# --- summary -----------------------------------------------------------------------
echo
say "Pixelfed is running: $URL/"
echo
echo "    Administrator:  $ADMIN_USER  ($ADMIN_EMAIL)"
${GENERATED_PASS:-false} && echo "    Password:       $ADMIN_PASS   (change it after the first login)"
echo "    Admin area:     $URL/i/admin/dashboard"
echo
if [ "$DOMAIN" != localhost ]; then
    echo "Remaining steps on the host ($NGINX_CONF):"
    echo "    sudo cp $PWD/$NGINX_CONF /etc/nginx/sites-available/$DOMAIN"
    echo "    sudo ln -s /etc/nginx/sites-available/$DOMAIN /etc/nginx/sites-enabled/"
    echo "    sudo nginx -t && sudo systemctl reload nginx"
    echo "    sudo certbot --nginx -d $DOMAIN"
    echo
fi
if $AS_ROOT; then
    echo "Updates:  sudo $PWD/update.sh"
else
    echo "Updates:  ./update.sh"
fi
