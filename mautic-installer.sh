#!/bin/bash

#Variables

db_name='mautic'
db_user='mautic'
web_root='/var/www/mautic'
#pass='pass'
#domain='example.com'
#email='changethis@example.com'
timezone='America/Sao_Paulo'

printf "Mysql database password for %s user:\n" "$db_user"
read -r pass
printf "Mautic installation domain (has to be already configured):\n"
read -r domain
printf "Mautic admin email:\n"
read -r email

### Set default parameters

sitesEnabled='/etc/apache2/sites-enabled/'
sitesAvailable='/etc/apache2/sites-available/'
sitesAvailabledomain=$sitesAvailable$domain.conf
export DEBIAN_FRONTEND=noninteractive
#####

if [ "$(whoami)" != 'root' ]; then
	echo $"You have no permission to run $0 as non-root user. Please use sudo"
		exit 1;
fi

#Ensure it only works on ubuntu and install apps for specific versions
if uname -a | grep -q Ubuntu; then
        lsb_release -d | grep -oh 'Ubuntu.*'

        echo "Updating the repository."
        add-apt-repository -y ppa:certbot/certbot
        apt-get update
        echo "Installing LAMP packages"
        apt-get --assume-yes install apache2 mysql-server php php-cli libapache2-mod-php php-mysql unzip python-certbot-apache
        apt-get --assume-yes install php-zip php-xml php-imap php-opcache php-apcu php-memcached php-mbstring php-curl php-amqplib php-mbstring php-bcmath php-intl


        x=$(lsb_release -rs)
        if (($(echo "$x < 18.04" | bc -l) ));then
                echo "old version"
                apt-get --assume-yes install php-mcrypt
        fi
else
        echo "This script is only compatible and tested on Ubuntu"
        exit 1
fi
cd /etc/apache2/mods-enabled/ || exit
sed -e 's/\s*DirectoryIndex.*$/\tDirectoryIndex index\.php index\.html index\.cgi index\.pl index\.xhtml index\.htm/' \
    dir.conf > /tmp/dir.conf && mv /tmp/dir.conf dir.conf
systemctl restart apache2

# TODO: Mysql easy install with secure root printed at the end
while true; do
    read -p "Do you wish to secure your mysql installation? Y/N: " yn
    case $yn in
        [Yy]* ) mysql_secure_installation; break;;
        [Nn]* ) break;;
        * ) echo "Please answer yes or no.";;
    esac
done

mysql -e "DROP DATABASE IF EXISTS ${db_name};"
mysql -e "CREATE DATABASE ${db_name} /*\!40100 DEFAULT CHARACTER SET utf8 */;"
mysql -e "DROP USER IF EXISTS ${db_user}@localhost;"
mysql -e "CREATE USER ${db_user}@localhost IDENTIFIED BY '${pass}';"
mysql -e "GRANT ALL PRIVILEGES ON ${db_name}.* TO '${db_user}'@'localhost';"
mysql -e "FLUSH PRIVILEGES;"

cd

curl -s https://api.github.com/repos/mautic/mautic/releases/latest \
| grep "browser_download_url.*zip" \
| cut -d : -f 2,3 \
| tr -d \" \
| tail -1 | wget -O mautic.zip -qi -

unzip -o mautic.zip -d $web_root
rm mautic.zip

apacheUser=$(ps -ef | egrep '(httpd|apache2|apache)' | grep -v root | head -n1 | awk '{print $1}')
# Set permissions for apache
cd $web_root || exit
chown -R $USER:$apacheUser .
find . -type d -exec chmod 755 {} \;
find . -type f -exec chmod 644 {} \;
chmod -R g+w app/cache/
chmod -R g+w app/logs/
chmod -R g+w app/config/
chmod -R g+w media/files/
chmod -R g+w media/images/
chmod -R g+w translations/

### check if domain already exists
if [ -e $sitesAvailabledomain ]; then
    echo -e "This domain already exists.\nRemoving...."

    ### disable website
    a2dissite $domain

    ### restart Apache
    /etc/init.d/apache2 reload

    ### Delete virtual host rules files
    rm $sitesAvailabledomain
    ### show the finished message
    echo -e "Complete!\nVirtual Host $domain has been removed."
fi

### create virtual host rules file
if ! echo "
<VirtualHost *:80>
    ServerAdmin $email
    ServerName $domain
    ServerAlias www.$domain
    DocumentRoot $web_root
    <Directory />
        AllowOverride All
    </Directory>
    <Directory $web_root>
        Options Indexes FollowSymLinks MultiViews
        AllowOverride all
        Require all granted
    </Directory>
    ErrorLog /var/log/apache2/$domain-error.log
    LogLevel error
    CustomLog /var/log/apache2/$domain-access.log combined
</VirtualHost>" > $sitesAvailabledomain
then
    echo -e $"There is an ERROR creating $domain file"
    exit;
else
    echo -e $"\nNew Virtual Host Created\n"
fi

### enable website
a2ensite $domain

ini=$(sudo find /etc/ -name php.ini | grep 'apache2')
sed 's#^;*date\.timezone[[:space:]]=.*$#date.timezone = "'"$timezone"'"#' $ini > /tmp/timezone.conf && mv /tmp/timezone.conf $ini

### restart Apache
/etc/init.d/apache2 reload

#Setup SSL for https
certbot -d $domain --non-interactive --redirect --keep-until-expiring --agree-tos --apache -m $email

touch /var/log/cron.pipe
chown $USER:$apacheUser /var/log/cron.pipe
chmod 664 /var/log/cron.pipe

(crontab -u $apacheUser -l 2>/dev/null; echo "8,23,38,52 * * * *   php /var/www/mautic/app/console mautic:segments:update --env=prod > /var/log/cron.pipe 2>&1") | crontab -u $apacheUser -
(crontab -u $apacheUser -l 2>/dev/null; echo "       */5 * * * *   php /var/www/mautic/app/console mautic:import --env=prod > /var/log/cron.pipe 2>&1") | crontab -u $apacheUser -
(crontab -u $apacheUser -l 2>/dev/null; echo "5,20,35,50 * * * *   php /var/www/mautic/app/console mautic:campaigns:rebuild --env=prod > /var/log/cron.pipe 2>&1") | crontab -u $apacheUser -
(crontab -u $apacheUser -l 2>/dev/null; echo "2,17,32,47 * * * *   php /var/www/mautic/app/console mautic:campaigns:trigger --env=prod > /var/log/cron.pipe 2>&1") | crontab -u $apacheUser -
(crontab -u $apacheUser -l 2>/dev/null; echo "0,15,30,45 * * * *   php /var/www/mautic/app/console mautic:messages:send --env=prod > /var/log/cron.pipe 2>&1") | crontab -u $apacheUser -
(crontab -u $apacheUser -l 2>/dev/null; echo "2,17,32,47 * * * *   php /var/www/mautic/app/console mautic:emails:send --env=prod > /var/log/cron.pipe 2>&1") | crontab -u $apacheUser -
(crontab -u $apacheUser -l 2>/dev/null; echo "4,19,34,49 * * * *   php /var/www/mautic/app/console mautic:email:fetch --env=prod > /var/log/cron.pipe 2>&1") | crontab -u $apacheUser -
(crontab -u $apacheUser -l 2>/dev/null; echo "6,21,36,51 * * * *   php /var/www/mautic/app/console mautic:social:monitoring --env=prod > /var/log/cron.pipe 2>&1") | crontab -u $apacheUser -
(crontab -u $apacheUser -l 2>/dev/null; echo "8,23,38,53 * * * *   php /var/www/mautic/app/console mautic:webhooks:process --env=prod > /var/log/cron.pipe 2>&1") | crontab -u $apacheUser -
(crontab -u $apacheUser -l 2>/dev/null; echo "10,25,40,59 * * * *   php /var/www/mautic/app/console mautic:broadcasts:send --env=prod > /var/log/cron.pipe 2>&1") | crontab -u $apacheUser -
(crontab -u $apacheUser -l 2>/dev/null; echo "         * 1 * * *   php /var/www/mautic/app/console mautic:maintenance:cleanup --days-old=365 --env=prod > /var/log/cron.pipe 2>&1") | crontab -u $apacheUser -
(crontab -u $apacheUser -l 2>/dev/null; echo "        0 4 15 * *   php /var/www/mautic/app/console mautic:iplookup:download --env=prod > /var/log/cron.pipe 2>&1") | crontab -u $apacheUser -
(crontab -u $apacheUser -l 2>/dev/null; echo "       */5 * * * *   php /var/www/mautic/app/console mautic:reports:scheduler --env=prod > /var/log/cron.pipe 2>&1") | crontab -u $apacheUser -
(crontab -u $apacheUser -l 2>/dev/null; echo "        0 5 10 * *   php /var/www/mautic/app/console mautic:unusedip:delete --env=prod > /var/log/cron.pipe 2>&1") | crontab -u $apacheUser -

### show the finished message
echo -e $"Complete! \nYou now have a new Virtual Host \nYour new host is: https://$domain \nAnd its located at $web_root"