#!/bin/sh
set -e

composer install --no-interaction --prefer-dist
exec php artisan test
