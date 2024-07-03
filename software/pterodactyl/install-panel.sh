#!/bin/bash
set -e

# Add repositories and install necessary packages
apt update
apt -y install software-properties-common curl apt-transport-https ca-certificates gnupg

# Add PHP repository
LC_ALL=C.UTF-8 add-apt-repository -y ppa:ondrej/php

# Add Redis repository
curl -fsSL https://packages.redis.io/gpg | sudo gpg --dearmor -o /usr/share/keyrings/redis-archive-keyring.gpg
echo "deb [signed-by=/usr/share/keyrings/redis-archive-keyring.gpg] https://packages.redis.io/deb $(lsb_release -cs) main" | sudo tee /etc/apt/sources.list.d/redis.list

# Add MariaDB repository
curl -sS https://downloads.mariadb.com/MariaDB/mariadb_repo_setup | sudo bash

# Update repositories again after adding new ones
apt update

# Install required packages
apt -y install php8.1 php8.1-{common,cli,gd,mysql,mbstring,bcmath,xml,fpm,curl,zip} mariadb-server nginx tar unzip git redis-server
curl -sS https://getcomposer.org/installer | sudo php -- --install-dir=/usr/local/bin --filename=composer

# Generate random password for MySQL user 'pterodactyl'
mysql_password=$(openssl rand -base64 16)
mysql_command="CREATE DATABASE panel;
CREATE USER 'pterodactyl'@'127.0.0.1' IDENTIFIED BY '${mysql_password}';
GRANT ALL PRIVILEGES ON panel.* TO 'pterodactyl'@'127.0.0.1' WITH GRANT OPTION;
FLUSH PRIVILEGES;"

# Create Pterodactyl directory
mkdir -p /var/www/pterodactyl
cd /var/www/pterodactyl

# Download and extract the latest Pterodactyl panel
curl -Lo panel.tar.gz https://github.com/pterodactyl/panel/releases/latest/download/panel.tar.gz
tar -xzvf panel.tar.gz
chmod -R 755 storage/* bootstrap/cache/

# Execute MySQL commands
echo "${mysql_command}" | mysql -u root -p

# Setup Pterodactyl .env file and dependencies
cp .env.example .env
composer install --no-dev --optimize-autoloader
php artisan key:generate --force
php artisan p:environment:setup
php artisan p:environment:database
php artisan p:environment:mail
php artisan migrate --seed --force
php artisan p:user:make

# Set correct permissions for NGINX
chown -R www-data:www-data /var/www/pterodactyl/*

# Setup Pterodactyl Queue Worker service
cat <<EOF > /etc/systemd/system/pteroq.service
[Unit]
Description=Pterodactyl Queue Worker
After=redis-server.service

[Service]
User=www-data
Group=www-data
Restart=always
ExecStart=/usr/bin/php /var/www/pterodactyl/artisan queue:work --queue=high,standard,low --sleep=3 --tries=3
StartLimitInterval=180
StartLimitBurst=30
RestartSec=5s

[Install]
WantedBy=multi-user.target
EOF

# Enable and start services
systemctl enable --now redis-server
systemctl enable --now mariadb
systemctl enable --now nginx
systemctl enable --now pteroq.service

# Add cronjob for Pterodactyl scheduler
(crontab -l 2>/dev/null; echo "* * * * * php /var/www/pterodactyl/artisan schedule:run >> /dev/null 2>&1") | crontab -

# Output MySQL user 'pterodactyl' password
echo "MySQL 'pterodactyl' user password: ${mysql_password}"
