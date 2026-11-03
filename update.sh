#!/usr/bin/env bash
#
# Updates a running installation (on a server: as root, sudo /opt/pixelfed/<domain>/update.sh):
#   1. this repository (Docker setup)   git pull; containers rebuilt only if it changed
#   2. Pixelfed (the web root)          to PIXELFED_VERSION from .env (latest = newest
#                                       release, dev = development branch, or a tag);
#                                       if there is something new: database dump to
#                                       backups/, maintenance mode, checkout as www-data,
#                                       composer install, migrations, caches, Horizon restart
#
# Photos (storage/), Pixelfed's .env and the database contents are never touched.
#
# Usage: ./update.sh [-f] [-r]
#   -f   run the Pixelfed steps even if the version did not change
#   -r   rebuild the containers even if the Docker setup did not change
#        (e.g. for a new Debian/PHP patch release of the base image)
#
set -euo pipefail

main() {
    cd "$(dirname "$0")"
    source lib/common.sh

    local force=false rebuild=false skip_pull=false opt
    while getopts "frPh" opt; do
        case "$opt" in
            f) force=true ;;
            r) rebuild=true ;;
            P) skip_pull=true ;;    # internal: after this script was updated by git pull
            *) sed -n '2,18p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        esac
    done

    require_docker
    [ -w .git ] || fail "No write access to this repository – on a server run as root: sudo $PWD/update.sh"
    [ -f .installed ] || fail "Pixelfed is not installed yet – run ./install.sh first."
    resolve_htdocs
    check_htdocs_owner

    # --- 1. Docker setup ------------------------------------------------------------
    if ! $skip_pull; then
        say "Docker setup:"
        local before
        before=$(git rev-parse HEAD)
        git fetch -q
        git merge-base --is-ancestor HEAD '@{u}' \
            || fail "This repository has local commits – merge or rebase them first (git log @{u}..HEAD)."
        git merge -q --ff-only '@{u}'
        if [ -n "$(git diff --name-only "$before" HEAD -- Dockerfile docker-compose.yml config)" ]; then
            rebuild=true
        fi
        if [ -n "$(git diff --name-only "$before" HEAD -- update.sh lib)" ]; then
            say "update.sh itself changed – continuing with the new version …"
            exec "$0" -P $($force && echo -f) $($rebuild && echo -r)
        fi
    fi
    if $rebuild; then
        say "Rebuilding the containers …"
        compose build --pull
    fi
    compose up -d
    say "Docker setup: $(git rev-parse --short HEAD)"

    # --- 2. Pixelfed ------------------------------------------------------------------
    resolve_version
    say "Pixelfed: checking $REF …"
    fetch_ref
    local current
    current=$(web git -C "$HTDOCS" rev-parse HEAD)
    if [ "$current" = "$TARGET" ] && ! $force; then
        say "Pixelfed is up to date ($REF, $(web git -C "$HTDOCS" rev-parse --short HEAD))."
        return
    fi

    compose up -d --wait db redis web
    backup_database "$(web git -C "$HTDOCS" describe --tags --always)"

    artisan down
    trap '[ $? = 0 ] || warn "Update failed – Pixelfed is still in maintenance mode. Fix the problem and run: $0 -f"' EXIT
    checkout_ref
    composer_install
    finish_app
    artisan horizon:terminate
    artisan up
    compose up -d
    say "Done: Pixelfed $REF ($(web git -C "$HTDOCS" rev-parse --short HEAD))"
}

# backup_database LABEL – gzipped dump to backups/, keeps the newest 10
backup_database() {
    local file
    file="backups/$(date +%Y%m%d-%H%M%S)-$1.sql.gz"
    say "Database dump: $file"
    mkdir -p backups
    chmod 700 backups
    compose exec -T db sh -c 'exec mariadb-dump -uroot -p"$MARIADB_ROOT_PASSWORD" --single-transaction --routines "$MARIADB_DATABASE"' \
        | gzip > "$file"
    chmod 600 "$file"
    ls -1t backups/*.sql.gz | tail -n +11 | while read -r old; do rm -f "$old"; done
}

main "$@"
exit
