FROM php:8.4-apache

RUN apt-get update && apt-get install -y --no-install-recommends \
    libpng-dev \
    libjpeg62-turbo-dev \
    libfreetype6-dev \
    libzip-dev \
    libicu-dev \
    libxml2-dev \
    unzip \
    git \
    libonig-dev \
    mariadb-client \
    zlib1g-dev \
    libcurl4-openssl-dev \
    && docker-php-ext-configure gd \
    && docker-php-ext-install -j$(nproc) gd zip intl exif mysqli pdo pdo_mysql mbstring curl pcntl \
    && ( \
      php -m | grep -q '^redis$' || pecl install redis \
    ) \
    && docker-php-ext-enable redis \
    && apt-get clean && rm -rf /var/lib/apt/lists/*
