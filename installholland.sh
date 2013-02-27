#!/bin/bash

# Script to install and configure Holland for OpenStack Private Cloud Support
# This script creates a backup user in MySQL, installs and configures Holland,
# and sets up a cron job to run Holland once a day.


usage()
{
cat << EOF
usage: $0 options

Script to install and configure Holland for OpenStack Private Cloud Support. This script creates a backup user in MySQL, installs and configures Holland, and sets up a cron job to run Holland once a day.

OPTIONS:
-h Show this message
-q Quiet

EXAMPLE:
sh $0 -q
EOF
}


while getopts "hq" OPTION
do
case $OPTION in
                h)
                  usage
                  exit 0
                  ;;
                q)
                  QUIET="1"
                  ;;
                                                                                                                                           
        esac
done


printext ()
{

if [ ! "$QUIET" = "1" ]
then
echo "$*"
fi

}


returncheck ()
{
if [ $? -ne 0 ]; then
        echo "$*"
	exit 1
else
        printext "Success!"
fi
}


# Create the replication user in mysql
printext "Creating the MySQL replication user."
BKUSER="os_backup_user"
USERPASS=$( tr -cd '[:alnum:]' < /dev/urandom | fold -w30 | head -n1)

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

returncheck "Error, $BKUSER not created succesfully.  Investigate manually"

# Install Holland
printext "Installing Holland."

OS_VERSION=`lsb_release -i | awk -F ':' '{print $2}' | cut -f2`"_"`lsb_release -r | awk -F ':' '{print $2}' | cut -f2`
sudo wget -q http://download.opensuse.org/repositories/home:/holland-backup/x$OS_VERSION/Release.key -O - | sudo apt-key add - >/dev/null
sudo echo "deb http://download.opensuse.org/repositories/home:/holland-backup/x$OS_VERSION/ ./" > /etc/apt/sources.list.d/holland.list  
sudo apt-get update > /dev/null
sudo apt-get install -y holland holland-common holland-mysqldump > /dev/null

# Verify Holland was installed
sudo which holland > /dev/null

returncheck "Error:  Holland was not installed.  Investigate manually"

# Remove the default config if it exists
if [ -f /etc/holland/backupsets/default.conf ]; then
	sudo rm /etc/holland/backupsets/default.conf
fi

# Create an OpenStack mysqldump config
printext "Creating OpenStack MySQL dump configuration for Holland."
sudo holland -q  mk-config --name=OpenStack mysqldump >/dev/null 2>&1

OSCONFIG="/etc/holland/backupsets/OpenStack.conf"
SOCKET=$(sudo grep -A 5 "\[client\]" /etc/mysql/my.cnf | grep socket | awk -F '=' '{print $2}' | cut -d ' ' -f2 | sed 's/\//\\\//g')
PORT=$(sudo grep -A 5 "\[client\]" /etc/mysql/my.cnf | grep port | awk -F '=' '{print $2}' | cut -d ' ' -f2 | sed 's/\//\\\//g')


# Create the commvault file for mbu
cat > /usr/sbin/holland_cvmysqlsv << EOF
#!/usr/bin/python

# EASY-INSTALL-ENTRY-SCRIPT: 'holland-commvault==1.0dev','console_scripts','holland_cvmysqlsv'

__requires__ = 'holland-commvault==1.0dev'

import sys

from pkg_resources import load_entry_point



if __name__ == '__main__':

    sys.exit(

        load_entry_point('holland-commvault==1.0dev', 'console_scripts', 'holland_cvmysqlsv')()

    )
EOF

# Set permissions to 755
chmod 755 /usr/sbin/holland_cvmysqlsv

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

printext "Success!"

# Create cron job to run Holland 1x per day
printext "Creating daily cron job for Holland."
sudo echo '#!/bin/bash
holland backup OpenStack
' > /etc/cron.daily/holland

if [ -f /etc/cron.daily/holland ]; then
	sudo chmod +x /etc/cron.daily/holland
	printext "Success!"
else
	echo "Failed to create cron job.  Investigate manually."
fi


printext "Performing dry run to verify installation."
# Perform dry run of the backup
sudo holland -q bk -n OpenStack 

returncheck "Dry Run did not complete successfully. Investigate manually."
