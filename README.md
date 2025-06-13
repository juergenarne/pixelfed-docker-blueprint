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

3. Start the Docker enviornment

```bash
docker compose up -d --build
````

After Docker is fully started up and running:

4. Change into the ``src`` directory

```bash
cd src
````

5. Remove the ``.install.lock`` file

```bash
rm .install.lock
````

6. Run the installer

```bash
./install.sh
````

7. Configure your installation and take it from there: <https://docs.pixelfed.org/running-pixelfed/installation.html#configure-environment-variables>
