# PHP 8.5.12 – keep in sync with the image tag in docker-compose.yml
ARG PHP_VERSION=8.5.12
FROM php:${PHP_VERSION}-apache

# System packages and PHP extensions needed by Pixelfed:
#   libvips + ffi   image processing (IMAGE_DRIVER=vips, Pixelfed's default)
#   ffmpeg          video thumbnails
#   jpegoptim …     image optimisation (PF_OPTIMIZE_IMAGES)
#   git, unzip      composer
RUN apt-get update && apt-get install -y --no-install-recommends \
    git \
    unzip \
    mariadb-client \
    libpng-dev \
    libjpeg62-turbo-dev \
    libfreetype6-dev \
    libwebp-dev \
    libzip-dev \
    libicu-dev \
    libffi-dev \
    libvips42t64 \
    ffmpeg \
    jpegoptim \
    optipng \
    pngquant \
    gifsicle \
    && docker-php-ext-configure gd --with-freetype --with-jpeg --with-webp \
    && docker-php-ext-install -j"$(nproc)" bcmath exif ffi gd intl pcntl pdo_mysql zip \
    && pecl install redis \
    && docker-php-ext-enable redis \
    && apt-get clean && rm -rf /var/lib/apt/lists/* /tmp/pear

COPY --from=composer:2 /usr/bin/composer /usr/bin/composer
# composer runs as www-data, whose home directory is not writable
ENV COMPOSER_HOME=/tmp/composer

RUN a2enmod rewrite headers
