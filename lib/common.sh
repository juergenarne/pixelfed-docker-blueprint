# Shared by install.sh and update.sh (sourced, not executed).
#
# Layout on a server (both scripts run as root):
#   /opt/pixelfed/<domain>       this repository, .env, mariadb/, backups/     root
#   /var/www/htdocs/<domain>     Pixelfed (APACHE_HTDOCS), incl. its .env       www-data
# Locally everything belongs to you and Pixelfed lives in ./src/htdocs.

say()  { printf '\033[1m%s\033[0m\n' "$*"; }
warn() { printf '\033[33mWarning:\033[0m %s\n' "$*" >&2; }
fail() { printf '\033[31mError:\033[0m %s\n' "$*" >&2; exit 1; }

random() { LC_ALL=C tr -dc 'A-Za-z0-9' < /dev/urandom | head -c "${1:-24}" || true; }

# --- env files ---------------------------------------------------------------------
# env_get FILE KEY – value of KEY (unquoted as written in the file)
env_get() { grep -E "^$2=" "$1" 2>/dev/null | tail -n 1 | cut -d= -f2- || true; }

# env_set FILE KEY VALUE – replace or append KEY=VALUE (keeps owner and mode of FILE)
env_set() {
    local tmp
    tmp=$(mktemp)
    if grep -q "^$2=" "$1"; then
        K="$2" V="$3" awk 'index($0, ENVIRON["K"] "=") == 1 { print ENVIRON["K"] "=" ENVIRON["V"]; next } { print }' "$1" > "$tmp"
    else
        cat "$1" > "$tmp"
        [ -z "$(tail -c 1 "$1")" ] || echo >> "$tmp"
        printf '%s=%s\n' "$2" "$3" >> "$tmp"
    fi
    cat "$tmp" > "$1"
    rm -f "$tmp"
}

# dotenv_quote VALUE – quoted for Laravel's .env (single quotes are taken literally)
dotenv_quote() {
    case $1 in
        *"'"*) local v=${1//\\/\\\\}; v=${v//\"/\\\"}; printf '"%s"' "$v" ;;
        *) printf "'%s'" "$1" ;;
    esac
}

# --- docker ------------------------------------------------------------------------
require_docker() {
    command -v docker >/dev/null 2>&1 || fail "Docker is not installed (https://docs.docker.com/get-docker/)."
    docker info >/dev/null 2>&1 || fail "Docker is not running."
    docker compose version >/dev/null 2>&1 || fail "Docker Compose v2 (docker compose) is not installed."
}
compose() { docker compose "$@"; }

# artisan ARGS… / pf CMD… – run in the web container as www-data
pf()      { compose exec -T --user www-data web "$@"; }
artisan() { pf php artisan "$@"; }

# --- root / www-data ---------------------------------------------------------------
AS_ROOT=false
[ "$(id -u)" = 0 ] && AS_ROOT=true

# web CMD… – run CMD on the host as the owner of the web root (www-data on a server;
# from /, as www-data may not enter this directory)
web() { if $AS_ROOT; then (cd / && sudo -u www-data -H "$@"); else "$@"; fi; }

# resolve_htdocs – sets HTDOCS from APACHE_HTDOCS in .env
# (docker-compose.yml mounts it as it is: a relative path needs a leading ./)
resolve_htdocs() {
    HTDOCS=$(env_get .env APACHE_HTDOCS)
    case "$HTDOCS" in ""|*'$'*) HTDOCS=./src/htdocs ;; esac
    case "$HTDOCS" in /*|./*|../*) ;; *) HTDOCS="./$HTDOCS" ;; esac
    [ "$(env_get .env APACHE_HTDOCS)" = "$HTDOCS" ] || env_set .env APACHE_HTDOCS "$HTDOCS"
    if $AS_ROOT; then
        case "$HTDOCS" in
            /*) ;;
            *) fail "Running as root: APACHE_HTDOCS in .env must be the absolute path of the web root outside this directory, e.g. /var/www/htdocs/<domain>." ;;
        esac
    fi
}

check_htdocs_owner() {
    if $AS_ROOT && [ "$(stat -c %U "$HTDOCS")" != www-data ]; then
        fail "$HTDOCS does not belong to www-data – fix with: chown -R www-data:www-data $HTDOCS"
    fi
}

# --- pixelfed versions -------------------------------------------------------------
# latest_release REPO – newest release tag (no release candidates)
latest_release() {
    git ls-remote --tags --refs "$1" 'v*' | awk -F/ '{ print $3 }' \
        | grep -E '^v[0-9]+\.[0-9]+\.[0-9]+$' | sort -V | tail -n 1
}

# resolve_version – sets REF to the tag/branch PIXELFED_VERSION stands for
resolve_version() {
    local version
    version=$(env_get .env PIXELFED_VERSION)
    case "$version" in
        ""|latest) REF=$(latest_release "$(env_get .env PIXELFED_REPO)")
                   [ -n "$REF" ] || fail "Cannot determine the newest Pixelfed release." ;;
        *) REF=$version ;;
    esac
}

# fetch_ref – fetch the web root's repository, sets TARGET to the commit of REF
# (a branch such as dev or a release tag)
fetch_ref() {
    web git -C "$HTDOCS" fetch -q --tags --force origin
    TARGET=$(web git -C "$HTDOCS" rev-parse -q --verify "refs/remotes/origin/$REF^{commit}" \
        || web git -C "$HTDOCS" rev-parse -q --verify "refs/tags/$REF^{commit}") \
        || fail "Pixelfed version $REF does not exist in $(env_get .env PIXELFED_REPO)."
}
checkout_ref() { web git -C "$HTDOCS" checkout -q --detach "$TARGET"; }

# after every checkout: dependencies, then database and caches
composer_install() {
    pf composer install --no-dev --no-interaction --no-ansi --prefer-dist --optimize-autoloader
}
finish_app() {
    pf test -e public/storage || artisan storage:link
    artisan migrate --force
    artisan config:cache
    artisan route:cache
    artisan view:cache
}
