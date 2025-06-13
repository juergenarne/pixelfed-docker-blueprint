#!/bin/bash

LOCKFILE=".install.lock"

if [[ -f "$LOCKFILE" ]]; then
  echo "Pixelfed has already been installed. ($LOCKFILE found)"
  exit 1
fi

echo "Starting Installation..."

rm -rf ./htdocs;
git clone -b dev https://github.com/pixelfed/pixelfed.git htdocs;
chmod -R 0775 ./htdocs;
find ./htdocs -type d -exec chmod 755 {} \;
find ./htdocs -type f -exec chmod 644 {} \;
cd htdocs
composer install --no-ansi --no-interaction --optimize-autoloader;
cp .env.example .env;

echo "Installation is done!";
cd ..;
touch "$LOCKFILE"
echo "Lockfile created: $LOCKFILE"
echo "You may now start configuring Pixelfed by modifying the ./htdocs/.env File"
echo "To reinstall Pixelfed remove lockfile $LOCKFILE"