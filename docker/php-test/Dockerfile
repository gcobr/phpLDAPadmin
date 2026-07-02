FROM php:8.4-cli

RUN apt-get update \
	&& apt-get install -y --no-install-recommends libldap2-dev libzip-dev libonig-dev unzip git \
	&& rm -rf /var/lib/apt/lists/* \
	&& docker-php-ext-configure ldap \
	&& docker-php-ext-install ldap mbstring bcmath zip pdo

COPY --from=composer:2 /usr/bin/composer /usr/bin/composer

WORKDIR /app

COPY docker/php-test/entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

ENTRYPOINT ["/entrypoint.sh"]
