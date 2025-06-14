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
docker exec -it pixelfed-web /bin/bash
````
  
9. Take it from there: <https://docs.pixelfed.org/running-pixelfed/installation.html#configure-environment-variables>

10. Configure your Nginx Proxy
