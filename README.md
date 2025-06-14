# Pixelfed Docker Setup

Steps to set up your own local Pixelfed on a Docker with MariaDb Apache and Redis:

```bash
cd /some/docker/home/dir
````

1. Clone the repo from github.com

```bash
git clone https://github.com/juergenarne/pixelfed_docker_blueprint.git . 
````

2. Modify your ``.env`` file

```bash
vi .env
````

set the variables for

- MYSQL_ROOT_PASSWORD
- MYSQL_DATABASE
- MYSQL_USER
- MYSQL_PASSWORD

to a safe and conveniant value

To generate a safe password use:

```bash
./password.sh
````

optionally set the variables for all ``*_PORT`` variables to values fitting your enviornments needs if you use multiple docker setups to avoid collisions

3. Change into the ``src`` directory

```bash
cd src
````

4. Remove the ``.install.lock`` file

```bash
rm .install.lock
````

5. Run the installer

```bash
./install.sh
````

6. Configure your installation by modifying the Pixelfed ``.env`` file

```bash
cd htdocs
vi .env
````

Modify all necessary information and add the DB credentials from the dockers ``.env`` file


7. Start the Docker enviornment

```bash
docker compose up -d --build
````

After Docker is fully started up and running 

8. Login to your apache php web container

```bash
docker exec -it pixelfed-apache /bin/bash
````
  
9. One time setup tasks:

Setting up services

One-time setup tasks
One time only, you need to generate the secret APP_KEY:

```bash
php artisan key:generate
````

One time only, the storage/ directory must be linked to the application:

```bash
php artisan storage:link
````

Database migrations must be run:

```bash
php artisan migrate --force
````

If you want to enable support for location data:

```bash
php artisan import:cities
````

If you enabled ActivityPub federation:

```bash
php artisan instance:actor
````

If you enabled OAuth:

```bash
php artisan passport:keys
````

Routes should be cached whenever the source code changes or whenever you change routes:

```bash
php artisan route:cache
php artisan view:cache
````

Every time you edit your .env file, you must run this command in the *-apache docker container to have the changes take effect:

```bash
php artisan config:cache
````

__see: <https://docs.pixelfed.org/running-pixelfed/installation.html#configure-environment-variables>__

11. Configure your Nginx Proxy
