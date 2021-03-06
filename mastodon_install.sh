#!/bin/bash

DOMAIN=test.example.com
WEBSERVERUSER=www-data
WEBSERVERGROUP=www-data

# Check to ensure the script is run as root/sudo
if [ "$(id -u)" != "0" ]; then
	echo "This script must be run as root. Later hater." 1>&2
	exit 1
fi

function repos_setup() {
	apt -y install apt-transport-https
	wget -qO - https://deb.nodesource.com/gpgkey/nodesource.gpg.key | apt-key add -
	echo 'deb https://deb.nodesource.com/node_4.x jessie main' > /etc/apt/sources.list.d/nodesource.list
}

function prereqs() {
	apt update
	apt -y install nodejs ack-grep rbenv build-essential curl ffmpeg git imagemagick libpq-dev libxml2-dev libxslt1-dev git postgresql postgresql-contrib redis-server redis-tools ruby2.3 ruby2.3-dev apache2
	npm install -g npm yarn json json-diff
	rbenv install 2.3.1
}

function db_setup() {
	su - postgres
	psql
	CREATE USER mastodon CREATEDB;
	exit
}

function build_stage() {
	mkdir -p /var/www/html/
	cd /var/www/html/
	git clone https://github.com/tootsuite/mastodon.git $DOMAIN
	rm -rf $DOMAIN/.git
	chown -R $WEBSERVERUSER:$WEBSERVERGROUP $DOMAIN

	gem install bundler
	bundle install --deployment --without development test
	yarn install
}

function config_setup() {
	cp .env.production.sample .env.production

	sed "s@LOCAL_DOMAIN=example.com@LOCAL_DOMAIN=$DOMAIN@g" -i .env.production
	sed "s@PAPERCLIP_SECRET=@PAPERCLIP_SECRET=$(< /dev/urandom tr -dc _A-Z-a-z-0-9 | head -c32; echo)@g" -i .env.production
	sed "s@SECRET_KEY_BASE=@SECRET_KEY_BASE=$(< /dev/urandom tr -dc _A-Z-a-z-0-9 | head -c32; echo)@g" -i .env.production
	sed "s@OTP_SECRET=@OTP_SECRET=$(< /dev/urandom tr -dc _A-Z-a-z-0-9 | head -c32; echo)@g" -i .env.production

	RAILS_ENV=production bundle exec rails db:setup
	RAILS_ENV=production bundle exec rails assets:precompile
}

function apache2_setup() {
cat << 'EOF' > /etc/apache2/sites-enabled/$DOMAIN.conf
<VirtualHost *:443>

ServerAdmin admin@$DOMAIN
ServerName $DOMAIN
ErrorLog /var/log/$DOMAIN_error.log
TransferLog /var/log/$DOMAIN_access.log
LogLevel warn

<Location />
        Order allow,deny
        Allow from all
</Location>

ProxyPreserveHost On
ProxyPass / http://localhost:3000/
ProxyPassReverse / http://localhost:3000/

</VirtualHost>
EOF

	systemctl enable apache2
}

function systemd_setup() {

cat << 'EOF' > /etc/systemd/system/mastodon-web.service
[Unit]
Description=mastodon-web
After=network.target

[Service]
Type=simple
User=mastodon
WorkingDirectory=/var/www/html/$DOMAIN
Environment="RAILS_ENV=production"
Environment="PORT=3000"
ExecStart=/var/www/html/$DOMAIN/.rbenv/shims/bundle exec puma -C config/puma.rb
TimeoutSec=15
Restart=always

[Install]
WantedBy=multi-user.target
EOF

cat << 'EOF' > /etc/systemd/system/mastodon-sidekiq.service
[Unit]
Description=mastodon-sidekiq
After=network.target

[Service]
Type=simple
User=mastodon
WorkingDirectory=/var/www/html/$DOMAIN
Environment="RAILS_ENV=production"
Environment="DB_POOL=5"
ExecStart=/var/www/html/$DOMAIN/.rbenv/shims/bundle exec sidekiq -c 5 -q default -q mailers -q pull -q push
TimeoutSec=15
Restart=always

[Install]
WantedBy=multi-user.target
EOF

cat << 'EOF' > /etc/systemd/system/mastodon-streaming.service
[Unit]
Description=mastodon-streaming
After=network.target

[Service]
Type=simple
User=mastodon
WorkingDirectory=/var/www/html/$DOMAIN
Environment="NODE_ENV=production"
Environment="PORT=4000"
ExecStart=/usr/bin/npm run start
TimeoutSec=15
Restart=always

[Install]
WantedBy=multi-user.target
EOF

	systemctl enable mastodon-*.service
	systemctl restart mastodon-*.service
}

repos_setup
prereqs
db_setup
build_stage
config_setup
apache2_setup
systemd_setup
