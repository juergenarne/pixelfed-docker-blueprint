#!/usr/bin/env bash
#
# One-time move of a Pixelfed instance in the old layout (this repository with Pixelfed
# in src/htdocs, everything owned by www-data, e.g. /var/www/htdocs/<domain>) to the
# server layout with separate owners:
#   /opt/pixelfed/<domain>        this repository, .env, mariadb/, backups/    root
#   /var/www/htdocs/<domain>      Pixelfed incl. its .env and storage/         www-data
# The old directory may be the new web root itself (the usual case): Pixelfed moves up
# into it, everything else moves to /opt.
#
# Photos (storage/) and the database contents are not modified. MariaDB is upgraded to
# the version of .env.dist (see --keep-mariadb). A backup (database dump, raw database
# files, storage/, both .env files) and a rollback script are created first.
# If Pixelfed was installed completely it is updated and started; otherwise run
# install.sh afterwards.
#
# Run as root from a copy outside the instance – this repository is moved:
#   curl -fsSL https://raw.githubusercontent.com/juergenarne/pixelfed-docker-blueprint/master/relocate-server.sh -o /tmp/relocate-server.sh
#   sudo bash /tmp/relocate-server.sh --domain example.com --dir /var/www/htdocs/example.com            # dry run
#   sudo bash /tmp/relocate-server.sh --domain example.com --dir /var/www/htdocs/example.com --apply    # move
#
# Options:
#   --domain NAME        domain of the instance: target directories, container names (required)
#   --dir PATH           current directory of the instance (default: current directory)
#   --apply              really move (default: dry run, nothing is changed)
#   --opt PATH           new directory of this repository (default: /opt/pixelfed/<domain>)
#   --web PATH           new web root (default: /var/www/htdocs/<domain>)
#   --backup PATH        backup directory (default: /root/pixelfed-relocate-<domain>-<date>)
#   --no-storage-backup  no tar of storage/ (photos are moved, never changed)
#   --keep-mariadb       keep the current MariaDB version instead of upgrading
#   --version VERSION    PIXELFED_VERSION for .env: latest, dev or a tag (default: latest
#                        if the current checkout is part of the newest release, else dev)
#   --blueprint URL      this repository (default: https://github.com/juergenarne/pixelfed-docker-blueprint.git)
#
set -euo pipefail

SELF=$(readlink -f "$0"); ARGS=("$@")
APPLY=false; DOMAIN=""; CUR="$PWD"; OPT=""; WEB=""; BACKUP=""; STORAGE_BACKUP=true
KEEP_MARIADB=false; VERSION=""
BLUEPRINT_URL=https://github.com/juergenarne/pixelfed-docker-blueprint.git
BRANCH=master
while [ $# -gt 0 ]; do
    case "$1" in
        --apply) APPLY=true ;;
        --domain) DOMAIN="$2"; shift ;;
        --dir) CUR="$2"; shift ;;
        --opt) OPT="$2"; shift ;;
        --web) WEB="$2"; shift ;;
        --backup) BACKUP="$2"; shift ;;
        --no-storage-backup) STORAGE_BACKUP=false ;;
        --keep-mariadb) KEEP_MARIADB=true ;;
        --version) VERSION="$2"; shift ;;
        --blueprint) BLUEPRINT_URL="$2"; shift ;;
        -h|--help) sed -n '2,35p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "Unknown option: $1" >&2; exit 1 ;;
    esac
    shift
done

say()  { printf '\n\033[1m== %s\033[0m\n' "$*"; }
info() { printf '   %s\n' "$*"; }
warn() { printf '   \033[33mWARNING:\033[0m %s\n' "$*"; }
fail() { printf '\n\033[31mERROR:\033[0m %s\n' "$*" >&2; exit 1; }
run()  { if $APPLY; then "$@"; else info "[dry run] $*"; fi; }

[ "$(id -u)" = 0 ] || fail "Run as root: sudo bash $0 …"
[ -n "$DOMAIN" ] || fail "--domain is missing (e.g. --domain pnoom.gallery)."
[[ "$DOMAIN" =~ ^[a-z0-9.-]+$ ]] || fail "Invalid domain: $DOMAIN (lower case letters, digits, dots, dashes)."
CUR=$(cd "$CUR" 2>/dev/null && pwd -P) || fail "Directory $CUR not found."

# This repository is moved and replaced while the script runs: continue from a copy.
case "$SELF" in
    "$CUR"/*) COPY=$(mktemp); cp "$SELF" "$COPY"; exec bash "$COPY" "${ARGS[@]}" ;;
esac
cd "$CUR"

OPT=${OPT:-/opt/pixelfed/$DOMAIN}; WEB=${WEB:-/var/www/htdocs/$DOMAIN}
STAMP=$(date +%Y%m%d-%H%M%S)
BACKUP=${BACKUP:-/root/pixelfed-relocate-$DOMAIN-$STAMP}
APP_NAME=$(printf %s "$DOMAIN" | tr -c 'a-z0-9\n' '-')
# Pixelfed waits here between leaving the old and entering the new directory (same
# parent as the web root: a rename, the photos are not copied)
PARK="$(dirname "$WEB")/.$(basename "$WEB").relocate-$STAMP"

# git as root in a repository that belongs to someone else
rgit() { git -c safe.directory="$1" -C "$1" "${@:2}"; }
web()  { (cd / && sudo -u www-data -H "$@"); }

# env_get FILE KEY / env_set FILE KEY VALUE (keeps owner and mode of FILE)
env_get() { grep -E "^$2=" "$1" 2>/dev/null | tail -n 1 | cut -d= -f2- || true; }
env_set() {
    local tmp; tmp=$(mktemp)
    if grep -q "^$2=" "$1"; then
        K="$2" V="$3" awk 'index($0, ENVIRON["K"] "=") == 1 { print ENVIRON["K"] "=" ENVIRON["V"]; next } { print }' "$1" > "$tmp"
    else
        cat "$1" > "$tmp"; [ -z "$(tail -c 1 "$1")" ] || echo >> "$tmp"; printf '%s=%s\n' "$2" "$3" >> "$tmp"
    fi
    cat "$tmp" > "$1"; rm -f "$tmp"
}
unquote() { local v=$1; v=${v#[\"\']}; v=${v%[\"\']}; printf %s "$v"; }
dotenv_quote() {
    case $1 in
        *"'"*) local v=${1//\\/\\\\}; v=${v//\"/\\\"}; printf '"%s"' "$v" ;;
        *) printf "'%s'" "$1" ;;
    esac
}
existing() { local p=$1; while [ ! -d "$p" ]; do p=$(dirname "$p"); done; echo "$p"; }
kb() { local v; v=$(du -sk "$1" 2>/dev/null | cut -f1); echo "${v:-0}"; }

# =============================================================================
say "1. Checks"
# =============================================================================
for c in git docker sudo curl; do command -v $c >/dev/null || fail "$c is missing."; done
id www-data >/dev/null 2>&1 || fail "User www-data does not exist."
docker compose version >/dev/null 2>&1 || fail "Docker Compose v2 (docker compose) is missing."
compose() { docker compose "$@"; }

[ -d .git ] && [ -f docker-compose.yml ] && [ -f .env ] || fail "$CUR is not the Docker repository with a .env. Use --dir."
HTDOCS=$(env_get .env APACHE_HTDOCS); HTDOCS=${HTDOCS//\$\{APACHE_SRC\}/$(env_get .env APACHE_SRC)}
case "$HTDOCS" in ""|*'$'*) HTDOCS=src/htdocs ;; /*) fail "APACHE_HTDOCS is already absolute ($HTDOCS) – relocated already?" ;; esac
HTDOCS=${HTDOCS#./}
[ -f "$HTDOCS/artisan" ] || fail "$CUR/$HTDOCS contains no Pixelfed (artisan not found)."
[ -d "$HTDOCS/.git" ] || fail "$CUR/$HTDOCS is no git checkout – update.sh needs one."
PF_ENV="$HTDOCS/.env"
PORT=$(env_get .env APACHE_PORT); PORT=${PORT:-8080}
DB_NAME=$(env_get .env MYSQL_DATABASE); DB_USER=$(env_get .env MYSQL_USER)
DB_PASS=$(env_get .env MYSQL_PASSWORD); DB_ROOT=$(env_get .env MYSQL_ROOT_PASSWORD)
OLD_MARIADB=$(env_get .env MARIADB_VERSION)
# The database files (mounted as /var/lib/mysql) belong to MariaDB's UID and keep it;
# everything around them becomes root's. A relative path moves with this repository.
DB_LOCAL=$(env_get .env MARIADB_LOCAL_DIR); DB_DATA=$(env_get .env MARIADB_DATA_DIR)
DB_DIR=${DB_LOCAL:-./mariadb/data}${DB_DATA:-/lib}
case "$DB_DIR" in /*) DB_REL="" ;; *) DB_REL=${DB_DIR#./} ;; esac
[ -z "$DB_REL" ] || [ -d "$DB_REL" ] || fail "Database directory $CUR/$DB_REL not found (MARIADB_LOCAL_DIR/MARIADB_DATA_DIR)."
[ -n "$DB_NAME" ] && [ -n "$DB_ROOT" ] || fail "MYSQL_DATABASE or MYSQL_ROOT_PASSWORD missing in $CUR/.env."

info "instance:   $CUR  (owner $(stat -c %U "$CUR"))"
info "Pixelfed:   $CUR/$HTDOCS  (owner $(stat -c %U "$CUR/$HTDOCS"), storage: $(du -sh "$HTDOCS/storage" | cut -f1))"
info "database:   $CUR/${DB_REL:-$DB_DIR}  ($(du -sh "${DB_REL:-$DB_DIR}" | cut -f1), MariaDB ${OLD_MARIADB:-?})"
info "new:        $OPT  (root), containers $APP_NAME-*, port 127.0.0.1:$PORT"
info "            $WEB  (www-data)"

[ ! -e "$OPT" ] || fail "$OPT exists already."
[ "$WEB" = "$CUR" ] || [ ! -e "$WEB" ] || fail "$WEB exists already."
[ ! -e "$PARK" ] || fail "$PARK exists already."
case "$OPT/" in "$CUR"/*) fail "$OPT lies inside $CUR." ;; esac
case "$WEB/" in "$CUR"/*) [ "$WEB" = "$CUR" ] || fail "$WEB lies inside $CUR." ;; esac
# Pixelfed (photos) must stay on its file system: then every move is a rename
[ "$(stat -c %d "$CUR")" = "$(stat -c %d "$(existing "$(dirname "$WEB")")")" ] \
    || fail "$WEB is on another file system than $CUR – moving would copy all photos. Choose --web on the same file system."
if [ "$(stat -c %d "$CUR")" != "$(stat -c %d "$(existing "$(dirname "$OPT")")")" ]; then
    info "$OPT is on another file system – this repository and the database files are copied there."
fi

say "Containers (old setup)"
compose ps --all --format '   {{.Name}}: {{.State}} ({{.Image}})' || true
DB_RUNNING=false
[ "$(compose ps --status running --services 2>/dev/null | grep -cx db || true)" = 1 ] && DB_RUNNING=true
$DB_RUNNING || info "db is not running – it is started for the dump."
WEB_CONTAINER=$(compose ps -q web 2>/dev/null | head -n 1 || true)
WEB_IMAGE=""
[ -z "$WEB_CONTAINER" ] || WEB_IMAGE=$(docker inspect -f '{{.Config.Image}}' "$WEB_CONTAINER" 2>/dev/null || true)

say "This repository"
OLD_COMMIT=$(rgit "$CUR" rev-parse HEAD)
OLD_URL=$(rgit "$CUR" remote get-url origin 2>/dev/null || true)
# local changes (except Pixelfed in src/ and .env) are saved to the backup, then replaced
LOCAL_CHANGES=$(rgit "$CUR" --no-optional-locks status --porcelain --untracked-files=no -- . ":(exclude)src" ":(exclude).env")
if [ -n "$LOCAL_CHANGES" ]; then
    warn "local changes to versioned files – saved to the backup (local-changes.diff), then replaced:"
    echo "$LOCAL_CHANGES" | sed 's/^/      /'
fi
NEW_COMMIT=$(git ls-remote "$BLUEPRINT_URL" "refs/heads/$BRANCH" | cut -f1)
[ -n "$NEW_COMMIT" ] || fail "Cannot reach $BLUEPRINT_URL."
info "$(rgit "$CUR" rev-parse --short HEAD) -> ${NEW_COMMIT:0:7}  ($BLUEPRINT_URL, origin was: ${OLD_URL:-none})"

say "Pixelfed ($HTDOCS)"
PF_COMMIT=$(rgit "$CUR/$HTDOCS" rev-parse HEAD)
PF_BRANCH=$(rgit "$CUR/$HTDOCS" symbolic-ref --short -q HEAD || echo "detached")
PF_URL=$(rgit "$CUR/$HTDOCS" remote get-url origin 2>/dev/null || true)
info "at ${PF_COMMIT:0:9} ($PF_BRANCH), origin: ${PF_URL:-none}"
PF_CHANGES=$(rgit "$CUR/$HTDOCS" --no-optional-locks status --porcelain --untracked-files=no || true)
if [ -n "$PF_CHANGES" ]; then
    warn "Pixelfed files changed on the server (they stay; a checkout of another version may refuse):"
    echo "$PF_CHANGES" | head -n 20 | sed 's/^/      /'
fi
LATEST=$(git ls-remote --tags --refs "${PF_URL:-https://github.com/pixelfed/pixelfed.git}" 'v*' | awk -F/ '{ print $3 }' \
    | grep -E '^v[0-9]+\.[0-9]+\.[0-9]+$' | sort -V | tail -n 1)
[ -n "$LATEST" ] || fail "Cannot determine the newest Pixelfed release."
if [ -z "$VERSION" ]; then
    # Going back from a newer dev checkout to the release could break the database:
    # latest only if the current commit is part of the newest release.
    # (as www-data: only the release tag is added to Pixelfed's repository, no files change)
    if web git -C "$CUR/$HTDOCS" fetch -q --no-tags origin "refs/tags/$LATEST:refs/tags/$LATEST" \
        && rgit "$CUR/$HTDOCS" merge-base --is-ancestor "$PF_COMMIT" "refs/tags/$LATEST"; then
        VERSION=latest
    else
        VERSION=dev
        warn "the current checkout is newer than $LATEST – PIXELFED_VERSION=dev (switch to latest later with the next release)"
    fi
fi
info "PIXELFED_VERSION=$VERSION  (newest release: $LATEST)"

INSTALLED=false; HAS_PF_ENV=false
if [ -f "$PF_ENV" ]; then
    HAS_PF_ENV=true
    info "Pixelfed .env: DB_HOST=$(env_get "$PF_ENV" DB_HOST), REDIS_HOST=$(env_get "$PF_ENV" REDIS_HOST), APP_URL=$(env_get "$PF_ENV" APP_URL)"
    case "$(unquote "$(env_get "$PF_ENV" APP_KEY)")" in base64:?*) INSTALLED=true ;; esac
else
    info "Pixelfed has no .env yet"
fi
$INSTALLED || info "no APP_KEY in Pixelfed's .env – not installed completely: run install.sh after the move."

NEW_MARIADB=$(curl -fsSL "${BLUEPRINT_URL%.git}/raw/$BRANCH/.env.dist" 2>/dev/null | grep -E '^MARIADB_VERSION=' | cut -d= -f2- || true)
$KEEP_MARIADB && NEW_MARIADB=$OLD_MARIADB
info "MariaDB ${OLD_MARIADB:-?} -> ${NEW_MARIADB:-version of .env.dist}"

NEED_KB=$(( 512000 + $(kb "${DB_REL:-$DB_DIR}") + $(kb "$HTDOCS/vendor") ))
$STORAGE_BACKUP && NEED_KB=$(( NEED_KB + $(kb "$HTDOCS/storage/app") ))
FREE_KB=$(df -Pk "$(existing "$(dirname "$BACKUP")")" | awk 'NR == 2 { print $4 }')
info "backup: $BACKUP – needs about $((NEED_KB / 1024)) MB, free: $((FREE_KB / 1024)) MB"
[ "$FREE_KB" -gt "$NEED_KB" ] || fail "Not enough disk space for the backup (or use --no-storage-backup / --backup)."

# =============================================================================
say "2. Backup (the site keeps running)"
# =============================================================================
run mkdir -m 700 -p "$BACKUP"
run cp -p .env "$BACKUP/env"
! $HAS_PF_ENV || run cp -p "$PF_ENV" "$BACKUP/pixelfed.env"
if $APPLY; then
    rgit "$CUR" diff HEAD -- . ":(exclude)src" ":(exclude).env" > "$BACKUP/local-changes.diff"
    # owners of all files (except the database), restored by rollback.sh
    find "$CUR" ${DB_REL:+-path "$CUR/$DB_REL" -prune -o} -printf '%U:%G\0%p\0' > "$BACKUP/owners"
    if ! $DB_RUNNING; then
        compose up -d db
    fi
    for _ in $(seq 1 60); do
        compose exec -T db sh -c 'exec mariadb-admin -uroot -p"${MARIADB_ROOT_PASSWORD:-$MYSQL_ROOT_PASSWORD}" ping' >/dev/null 2>&1 && break
        sleep 2
    done
    compose exec -T db sh -c 'exec mariadb-dump -uroot -p"${MARIADB_ROOT_PASSWORD:-$MYSQL_ROOT_PASSWORD}" --single-transaction --routines --databases "$0"' "$DB_NAME" \
        | gzip > "$BACKUP/database.sql.gz"
    TABLES=$(gzip -dc "$BACKUP/database.sql.gz" | grep -c 'CREATE TABLE' || true)
    info "database dump: $(du -h "$BACKUP/database.sql.gz" | cut -f1), $TABLES tables"
    if $INSTALLED && [ "$(gzip -dc "$BACKUP/database.sql.gz" | grep -c 'CREATE TABLE `users`' || true)" = 0 ]; then
        warn "the database has no users table – Pixelfed is treated as not installed (run install.sh afterwards)"
        INSTALLED=false
    fi
else
    info "[dry run] local changes > $BACKUP/local-changes.diff, owners of all files > $BACKUP/owners"
    info "[dry run] mariadb-dump $DB_NAME > $BACKUP/database.sql.gz"
fi
if $STORAGE_BACKUP; then
    run tar -C "$CUR/$HTDOCS" --exclude=./storage/framework --exclude=./storage/logs -czf "$BACKUP/storage.tar.gz" ./storage
fi
[ -z "$WEB_IMAGE" ] || run docker tag "$WEB_IMAGE" "pixelfed-rollback:relocate-$STAMP"

if $APPLY; then
    cat > "$BACKUP/rollback.sh" <<EOF
#!/usr/bin/env bash
# Moves the instance back to $CUR (state before $STAMP), including the database files
# (MariaDB cannot be downgraded). Photos were not changed; for emergencies they and a
# database dump are in this directory.
set -euo pipefail
[ ! -d "$OPT" ] || (cd "$OPT" && docker compose down) || true
[ ! -d "$WEB" ] || [ -e "$PARK" ] || mv "$WEB" "$PARK"
if [ -d "$OPT" ] && [ ! -e "$CUR" ]; then mv "$OPT" "$CUR"; fi
cd "$CUR"
git -c safe.directory="$CUR" reset -q --hard $OLD_COMMIT
${OLD_URL:+git -c safe.directory="$CUR" remote set-url origin "$OLD_URL"}
[ ! -s "$BACKUP/local-changes.diff" ] || git -c safe.directory="$CUR" apply "$BACKUP/local-changes.diff"
cp -p "$BACKUP/env" .env
rm -f .installed
rm -rf "$CUR/$HTDOCS"
mkdir -p "$CUR/$(dirname "$HTDOCS")"
mv "$PARK" "$CUR/$HTDOCS"
git -c safe.directory="$CUR/$HTDOCS" -C "$HTDOCS" checkout -q --detach $PF_COMMIT
$([ "$PF_BRANCH" = detached ] || echo "git -c safe.directory=\"$CUR/$HTDOCS\" -C \"$HTDOCS\" checkout -q -B \"$PF_BRANCH\" $PF_COMMIT")
$($HAS_PF_ENV && echo "cp -p \"$BACKUP/pixelfed.env\" \"$HTDOCS/.env\"")
# dependencies and caches of the old version
[ ! -d "$BACKUP/vendor" ] || { rm -rf "$HTDOCS/vendor"; cp -a "$BACKUP/vendor" "$HTDOCS/vendor"; }
rm -f "$HTDOCS"/bootstrap/cache/config.php "$HTDOCS"/bootstrap/cache/routes-*.php
$([ -n "$DB_REL" ] && echo "rm -rf \"$CUR/$DB_REL\" && cp -a \"$BACKUP/mariadb-data\" \"$CUR/$DB_REL\"")
echo "restoring the owners of all files …"
while IFS= read -r -d '' owner && IFS= read -r -d '' path; do chown -h "\$owner" "\$path" 2>/dev/null || true; done < "$BACKUP/owners"
${WEB_IMAGE:+docker tag "pixelfed-rollback:relocate-$STAMP" "$WEB_IMAGE"}
docker compose up -d
echo "Rolled back to $CUR."
EOF
    chmod 700 "$BACKUP/rollback.sh"
    info "rollback script: $BACKUP/rollback.sh"
fi

# =============================================================================
say "3. Move (the site is down from here on)"
# =============================================================================
run compose down
if [ -n "$DB_REL" ]; then
    # raw database files (the database is stopped): MariaDB is upgraded below and
    # cannot go back, rollback.sh restores them
    run cp -a "$DB_REL" "$BACKUP/mariadb-data"
fi
run mv "$CUR/$HTDOCS" "$PARK"
run mkdir -m 755 -p "$(dirname "$OPT")"
run mv "$CUR" "$OPT"
run mkdir -p "$(dirname "$WEB")"
run mv "$PARK" "$WEB"
if $APPLY; then cd "$OPT"; fi

# =============================================================================
say "4. This repository, owners and settings"
# =============================================================================
run find "$OPT" ${DB_REL:+-path "$OPT/$DB_REL" -prune -o} \( ! -user root -o ! -group root \) -exec chown -h root:root {} +
run chmod 755 "$OPT"
run git -C "$OPT" remote set-url origin "$BLUEPRINT_URL"
if $APPLY; then
    git fetch -q origin "$BRANCH" || fail "git fetch failed. Back: $BACKUP/rollback.sh"
    # replaces the old files (local changes are in the backup); the old .env was versioned
    git reset -q --hard "origin/$BRANCH"
    git branch -q -u "origin/$BRANCH" 2>/dev/null || true
    rmdir "$(dirname "$HTDOCS")" 2>/dev/null || true
    info "now at $(git rev-parse --short HEAD)"
else
    info "[dry run] git reset --hard to ${NEW_COMMIT:0:7}"
fi

# .env: new template, values of the old one
if $APPLY; then
    cp .env.dist .env
    chmod 600 .env
    env_set .env APP_NAME "$APP_NAME"
    env_set .env APP_DOMAIN "$DOMAIN"
    env_set .env APACHE_PORT "$PORT"
    env_set .env APACHE_HTDOCS "$WEB"
    env_set .env PIXELFED_VERSION "$VERSION"
    env_set .env MYSQL_DATABASE "$DB_NAME"
    env_set .env MYSQL_USER "$DB_USER"
    env_set .env MYSQL_PASSWORD "$DB_PASS"
    env_set .env MYSQL_ROOT_PASSWORD "$DB_ROOT"
    [ -n "$DB_LOCAL" ] && env_set .env MARIADB_LOCAL_DIR "$DB_LOCAL"
    [ -n "$DB_DATA" ] && env_set .env MARIADB_DATA_DIR "$DB_DATA"
    $KEEP_MARIADB && [ -n "$OLD_MARIADB" ] && env_set .env MARIADB_VERSION "$OLD_MARIADB"
    info ".env: APP_NAME=$APP_NAME, port $PORT, MariaDB $(env_get .env MARIADB_VERSION), PIXELFED_VERSION=$VERSION"
else
    info "[dry run] .env from .env.dist with APP_NAME=$APP_NAME, APACHE_HTDOCS=$WEB, port $PORT and the old passwords"
fi

run chown -R www-data:www-data "$WEB"
# Pixelfed's .env: the containers are now reached by their service names
if $HAS_PF_ENV; then
    if $APPLY; then
        env_set "$WEB/.env" DB_HOST "'db'"
        env_set "$WEB/.env" DB_PORT "'3306'"
        env_set "$WEB/.env" DB_DATABASE "$(dotenv_quote "$DB_NAME")"
        env_set "$WEB/.env" DB_USERNAME "$(dotenv_quote "$DB_USER")"
        env_set "$WEB/.env" DB_PASSWORD "$(dotenv_quote "$DB_PASS")"
        env_set "$WEB/.env" REDIS_HOST "'redis'"
        env_set "$WEB/.env" REDIS_PORT "'6379'"
        chmod 600 "$WEB/.env"
    else
        info "[dry run] Pixelfed .env: DB_HOST=db, REDIS_HOST=redis, DB_* from .env"
    fi
fi

# =============================================================================
say "5. Start"
# =============================================================================
if ! $APPLY; then
    info "[dry run] docker compose build, up; then $($INSTALLED && echo "checkout $VERSION, composer install, migrations, caches, Horizon" || echo "install.sh")"
    say "Dry run finished – nothing was changed. Run again with --apply to move."
    exit 0
fi

compose build --pull || fail "Building the image failed. Back: $BACKUP/rollback.sh"
compose up -d --wait db redis || fail "The database does not start (MariaDB upgrade?). Logs: cd $OPT && docker compose logs db – back: $BACKUP/rollback.sh"

if ! $INSTALLED; then
    say "Moved. Pixelfed was not installed completely – finish it now:"
    info "sudo $OPT/install.sh"
    info "Rollback:  $BACKUP/rollback.sh"
    exit 0
fi

compose up -d --wait web
pf()      { compose exec -T --user www-data web "$@"; }
artisan() { pf php artisan "$@"; }
if [ "$VERSION" = latest ]; then REF=$LATEST; else REF=$VERSION; fi
web git -C "$WEB" fetch -q --tags --force origin
TARGET=$(web git -C "$WEB" rev-parse -q --verify "refs/remotes/origin/$REF^{commit}" \
    || web git -C "$WEB" rev-parse -q --verify "refs/tags/$REF^{commit}") \
    || fail "Pixelfed version $REF does not exist. Back: $BACKUP/rollback.sh"
web git -C "$WEB" checkout -q --detach "$TARGET" || fail "Checkout of $REF failed (local changes?). Back: $BACKUP/rollback.sh"
info "Pixelfed $REF ($(web git -C "$WEB" rev-parse --short HEAD))"
# dependencies of the old version, restored by rollback.sh
[ ! -d "$WEB/vendor" ] || cp -a "$WEB/vendor" "$BACKUP/vendor"
pf composer install --no-dev --no-interaction --no-ansi --prefer-dist --optimize-autoloader
pf test -e public/storage || artisan storage:link
artisan migrate --force
pf test -f storage/oauth-private.key || artisan passport:keys --force
artisan config:cache
artisan route:cache
artisan view:cache
compose up -d
echo "$REF, $(date '+%Y-%m-%d %H:%M') (relocated)" > .installed

HDR=(-H "Host: $DOMAIN" -H "X-Forwarded-Proto: https")
ok=false
for _ in $(seq 1 40); do
    code=$(curl -s -o /dev/null -w '%{http_code}' "${HDR[@]}" "http://127.0.0.1:$PORT/" || true)
    [ "$code" = 200 ] && { ok=true; break; }
    sleep 3
done
$ok || fail "The home page does not answer (HTTP $code). Logs: cd $OPT && docker compose logs web – back: $BACKUP/rollback.sh"
info "home page: HTTP 200"
git_code=$(curl -s -o /dev/null -w '%{http_code}' "${HDR[@]}" "http://127.0.0.1:$PORT/.env" || true)
[ "$git_code" = 404 ] && info "/.env: 404" || warn "/.env answers $git_code (expected 404)"

say "Done. Please check the site and the admin area in the browser."
info "The web server now listens on 127.0.0.1:$PORT only – the reverse proxy must use that address."
info "Updates:   sudo $OPT/update.sh"
info "Rollback:  $BACKUP/rollback.sh"
info "Later:     rm -rf $BACKUP; docker rmi pixelfed-rollback:relocate-$STAMP"
