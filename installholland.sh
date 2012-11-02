#!/bin/bash

# Script to install and configure Holland for OpenStack Private Cloud Support
# This script creates a backup user in MySQL, installs and configures Holland,
# and sets up a cron job to run Holland once a day.

# Create the replication user in mysql
echo "Creating the MySQL replication user"
BKUSER="os_backup_user"
USERPASS=`< /dev/urandom tr -dc _A-Z-a-z-0-9 | head -c${1:-12};echo;`

# If '$BKUSER' exists, drop and recreate with proper permissions and password
USEREXISTS=`sudo mysql -e "SELECT COUNT(User) FROM mysql.user WHERE User='$BKUSER'" | grep [0-9]`

if [ "$USEREXISTS" != "0" ]; then
	sudo mysql -e "DROP USER '$BKUSER'@'localhost'"
        sudo mysql -e "FLUSH PRIVILEGES"
fi

sudo mysql -e "GRANT SELECT, SHOW VIEW, TRIGGER, LOCK TABLES, SUPER, REPLICATION CLIENT, RELOAD ON *.* TO '$BKUSER'@'localhost' IDENTIFIED BY '"$USERPASS"'" > /dev/null
sudo mysql -e "FLUSH PRIVILEGES" > /dev/null

# Verify backup user created successfully
mysql -u$BKUSER -p$USERPASS -e "quit"

if [ $? -ne 0 ]; then
	echo "Error, $BKUSER not created succesfully.  Investigate manually"
	exit 1
else
	echo "Success!"
fi

# Install Holland
echo "Installing Holland"

OS_VERSION=`lsb_release -i | awk -F ':' '{print $2}' | cut -f2`"_"`lsb_release -r | awk -F ':' '{print $2}' | cut -f2`
sudo wget http://download.opensuse.org/repositories/home:/holland-backup/x$OS_VERSION/Release.key -O - | sudo apt-key add -
sudo echo "deb http://download.opensuse.org/repositories/home:/holland-backup/x$OS_VERSION/ ./" | sudo tee -a /etc/apt/sources.list.d/holland.list > /dev/null
sudo apt-get update > /dev/null
sudo apt-get install -y holland holland-common holland-mysqldump > /dev/null

# Verify Holland was installed
sudo which holland > /dev/null

if [ $? -ne 0 ]; then
	echo "Error:  Holland was not installed.  Investigate manually"
	exit 1
else
	echo "Success!"
fi

# Remove the default config if it exists
if [ -f /etc/holland/backupsets/default.conf ]; then
	sudo rm /etc/holland/backupsets/default.conf
fi

# Create an OpenStack mysqldump config
echo "Creating OpenStack MySQL dump configuration for Holland"
sudo holland mk-config --name=OpenStack mysqldump > /dev/null

OSCONFIG="/etc/holland/backupsets/OpenStack.conf"
SOCKET=$(sudo grep -A 5 "\[client\]" /etc/mysql/my.cnf | grep socket | awk -F '=' '{print $2}' | cut -d ' ' -f2 | sed 's/\//\\\//g')
PORT=$(sudo grep -A 5 "\[client\]" /etc/mysql/my.cnf | grep port | awk -F '=' '{print $2}' | cut -d ' ' -f2 | sed 's/\//\\\//g')

echo $SOCKET
echo $PORT

sudo sed -i "s/backups-to-keep = 1/backups-to-keep = 7/" $OSCONFIG
sudo sed -i "s/# user = \"\" # no default/user = $BKUSER/" $OSCONFIG
sudo sed -i "s/# password = \"\" # no default/password = $USERPASS/" $OSCONFIG
sudo sed -i "s/# socket = \"\" # no default/socket = $SOCKET/" $OSCONFIG
sudo sed -i "s/# host = \"\" # no default/host = localhost/" $OSCONFIG
sudo sed -i "s/# port = \"\" # no default/port = $PORT/" $OSCONFIG
sudo sed -i "s/exclude-databases = ,/#exclude-databases = ,/" $OSCONFIG
sudo sed -i "s/exclude-tables = ,/#exclude-tables = ,/" $OSCONFIG
sudo sed -i "s/exclude-engines = ,/#exclude-engines = ,/" $OSCONFIG
sudo sed -i "s/additional-options = ,/#additional-options = ,/" $OSCONFIG

echo "Success!"

# Create cron job to run Holland 1x per day
echo "Creating daily cron job for Holland"
sudo echo '#!/bin/bash
holland backup OpenStack
' > /etc/cron.daily/holland

if [ -f /etc/cron.daily/holland ]; then
	sudo chmod +x /etc/cron.daily/holland
	echo "Success!"
else
	echo "Failed to create cron job.  Investigate manually."
fi

# Perform dry run of the backup
sudo holland bk -n OpenStack

if [ $? -ne 0 ]; then
	echo "Dry Run did not complete successfully.  Investigate manually."
else
	echo "Success!"
fi
