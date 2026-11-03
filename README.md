# Pixelfed Docker Blueprint

Pixelfed (newest release) on Docker: PHP 8.5.12 + Apache, Horizon (queue), scheduler,
MariaDB 12.3 and Redis 8. `install.sh` sets everything up and asks for whatever it
cannot know; `update.sh` keeps both this setup and Pixelfed up to date.

| Container             | Purpose                                         |
|-----------------------|-------------------------------------------------|
| `<name>-apache`       | Pixelfed web server, on `127.0.0.1:APACHE_PORT` |
| `<name>-horizon`      | queue worker (`php artisan horizon`)            |
| `<name>-scheduler`    | scheduled tasks (`php artisan schedule:work`)   |
| `<name>-db`           | MariaDB, not published on the host              |
| `<name>-redis`        | Redis, not published on the host               |

`<name>` is `APP_NAME` from `.env`, derived from the domain (`my-funny-domain.tld` →
`my-funny-domain-tld`), so several instances can run on one server.

## Server

Layout – root runs Docker and owns the setup, www-data owns Pixelfed:

| Path                                   | Content                                         | Owner                 |
|----------------------------------------|-------------------------------------------------|-----------------------|
| `/opt/pixelfed/my-funny-domain.tld`    | this repository, `.env`, `mariadb/`, `backups/` | `root:root`           |
| `/var/www/htdocs/my-funny-domain.tld`  | Pixelfed incl. its `.env` and `storage/` (photos), mounted into the containers | `www-data:www-data` |

### Install

```bash
sudo git clone https://github.com/juergenarne/pixelfed-docker-blueprint.git /opt/pixelfed/my-funny-domain.tld
cd /opt/pixelfed/my-funny-domain.tld
sudo ./install.sh
```

The installer

1. creates `.env` from `.env.dist` with random database passwords and asks for the
   domain, the host port (unique per instance) and the Pixelfed version,
2. clones Pixelfed as www-data into `/var/www/htdocs/<domain>`,
3. writes Pixelfed's own `.env` – asks for the instance name, HTTPS, registration,
   e-mail verification, federation (ActivityPub), city import and SMTP,
4. builds and starts the containers, runs `composer install`, `key:generate`, the
   migrations, `instance:actor`, `passport:keys` and the caches,
5. creates the administrator (empty password → a generated one is printed),
6. writes a ready-made host nginx configuration to `nginx/<domain>.conf`.

`./install.sh -h` lists the options (`-y` non-interactive, `-d DOMAIN`, `-p PORT`).
Running it again after the installation only (re)starts the containers.

### Host nginx

`nginx/<domain>.conf` proxies the domain to `127.0.0.1:APACHE_PORT` (port 80 only,
`client_max_body_size 100M`). Add it to the host nginx, certbot adds HTTPS:

```bash
sudo cp /opt/pixelfed/my-funny-domain.tld/nginx/my-funny-domain.tld.conf /etc/nginx/sites-available/my-funny-domain.tld
sudo ln -s /etc/nginx/sites-available/my-funny-domain.tld /etc/nginx/sites-enabled/
sudo nginx -t && sudo systemctl reload nginx
sudo certbot --nginx -d my-funny-domain.tld
```

### Update

```bash
sudo /opt/pixelfed/my-funny-domain.tld/update.sh
```

1. pulls this repository and rebuilds the containers if the Docker setup changed,
2. updates Pixelfed to `PIXELFED_VERSION` (`latest` = newest release, `dev`, or a fixed
   tag such as `v0.15.2`) – only if there is something new: database dump to
   `backups/` (newest 10 are kept), maintenance mode, checkout as www-data,
   `composer install`, migrations, caches, Horizon restart.

`-f` runs the Pixelfed steps even without a new version, `-r` rebuilds the containers
(e.g. for a patched base image).

### Moving an existing instance to this layout

Older instances live in one directory owned by www-data, with Pixelfed in `src/htdocs`
(e.g. `/var/www/htdocs/my-funny-domain.tld`). `relocate-server.sh` moves them once:
this repository, `.env` and the database files to `/opt/pixelfed/<domain>` (root),
Pixelfed itself up into `/var/www/htdocs/<domain>` (www-data). It keeps the passwords
and the port, points Pixelfed's `.env` to the new containers, upgrades MariaDB
(`--keep-mariadb` to keep the old version) and starts everything. Local changes to
files of this repository are saved to the backup, not carried over.

Run it from a copy outside the instance – the instance directory is moved:

```bash
curl -fsSL https://raw.githubusercontent.com/juergenarne/pixelfed-docker-blueprint/master/relocate-server.sh -o /tmp/relocate-server.sh
sudo bash /tmp/relocate-server.sh --domain my-funny-domain.tld --dir /var/www/htdocs/my-funny-domain.tld           # dry run
sudo bash /tmp/relocate-server.sh --domain my-funny-domain.tld --dir /var/www/htdocs/my-funny-domain.tld --apply   # move
```

The dry run shows what would happen and changes nothing. Before moving, the script
writes a backup to `/root/pixelfed-relocate-<domain>-<date>/`: database dump, raw
database files, `storage/`, both `.env` files, `vendor/`. It also writes a
`rollback.sh` there that restores the old state completely. The site is down from
`docker compose down` until the new containers answer (a few minutes: image build,
MariaDB upgrade).

Afterwards the web server listens on `127.0.0.1:<port>` only – point the reverse proxy
to that address. If Pixelfed was never installed completely (no `APP_KEY`), finish it
with `sudo /opt/pixelfed/<domain>/install.sh`.

## Local

```bash
git clone https://github.com/juergenarne/pixelfed-docker-blueprint.git pixelfed
cd pixelfed
./install.sh          # domain: localhost
```

Pixelfed is cloned into `./src/htdocs` and runs on `http://localhost:8080/`.

## Everyday commands

```bash
docker compose exec --user www-data web php artisan …     # artisan, e.g. user:create
docker compose logs -f web horizon                        # logs
```

After editing Pixelfed's `.env` (in the web root):

```bash
docker compose exec --user www-data web php artisan config:cache
docker compose restart horizon
```

See also <https://docs.pixelfed.org/running-pixelfed/installation.html>.
