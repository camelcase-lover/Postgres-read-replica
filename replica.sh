#!/bin/bash
sudo systemctl start postgresql
number=-1
while [ "$number" -ne 0 ]; do
    echo "To exit enter 0"
    CURRENT_USER=$(whoami)
    echo "Hello $CURRENT_USER"
    hour=$((10#$(date +%H)))
    if [ "$hour" -lt 12 ]; then
        greeting="You're up and fine, Good morning, want to create replica or check it exist."
    elif [ "$hour" -ge 12 ] && [ "$hour" -lt 17 ]; then
        greeting="Good afternoon, want create replica or check if exist."
    elif [ "$hour" -ge 17 ] && [ "$hour" -lt 22 ]; then
        greeting="It's getting late pal, sip coffee as you create your replica."
    else
        greeting="It is seems you chose this horrible life, get no sleep huh! Lets get everything done. Choose an option"
    fi
    echo "$greeting"
    echo "Options."
    echo "1. Check if replica exist"
    echo "2. Create replica."
    read -p "Choose an Option " number

    if [ "$number" -eq 1 ]; then
        sudo -u postgres psql -h 127.0.0.1 -p 5433 -c "SELECT pg_is_in_recovery();"
    elif [ "$number" -eq 2 ]; then
        echo "Starting replica creation process..."
        
        PG_VERSION=$(psql -V | awk '{print $3}' | cut -d. -f1)
        if [ -z "$PG_VERSION" ]; then
            PG_VERSION=$(ls /etc/postgresql/ | sort -V | tail -n 1)
        fi

        echo "Postgres version ${PG_VERSION}"

        echo "Configuring primary database for replication"
        sudo sed -i "s/#*wal_level.*/wal_level = replica/" /etc/postgresql/$PG_VERSION/main/postgresql.conf
        sudo sed -i "s/#*max_wal_senders.*/max_wal_senders = 10/" /etc/postgresql/$PG_VERSION/main/postgresql.conf
        sudo sed -i "s/#*wal_keep_size.*/wal_keep_size = 512MB/" /etc/postgresql/$PG_VERSION/main/postgresql.conf

        sudo systemctl restart postgresql

        if [ -d /var/lib/postgresql/$PG_VERSION/replica ]; then
            echo "Removing old replica directory"
            sudo systemctl stop postgresql-replica 2>/dev/null
            sudo rm -rf /var/lib/postgresql/$PG_VERSION/replica
        fi

        echo "Running pg_basebackup from primary"
        if ! sudo -u postgres pg_basebackup -p 5432 -D /var/lib/postgresql/$PG_VERSION/replica -Fp -P -R; then
            echo "Error: pg_basebackup failed! Aborting replica creation."
            continue
        fi

        if [ ! -f /var/lib/postgresql/$PG_VERSION/replica/PG_VERSION ]; then
            echo "Error: Replica data directory integrity check failed. Aborting.."
            continue
        fi
        
        echo "Copying pg_hba.conf to replica directory"
        sudo cp /etc/postgresql/$PG_VERSION/main/pg_hba.conf /var/lib/postgresql/$PG_VERSION/replica/

        echo "Creating conf.d dir"
        sudo mkdir -p /var/lib/postgresql/$PG_VERSION/replica/conf.d
        
        echo "Configuring postgresql.conf for port 5433"
        sudo tee -a /var/lib/postgresql/$PG_VERSION/replica/postgresql.conf > /dev/null <<EOF
port = 5433
listen_addresses = '127.0.0.1'
hot_standby = on
EOF

        if [ ! -f /var/lib/postgresql/$PG_VERSION/replica/PG_VERSION ]; then
            echo "Error: Replica data directory integrity check failed. Aborting."
            continue
        fi

        echo "Setting ownership to postgres user."
        sudo chown -R postgres:postgres /var/lib/postgresql/$PG_VERSION/replica
        sudo chmod 700 /var/lib/postgresql/$PG_VERSION/replica

        if [ ! -f /etc/systemd/system/postgresql-replica.service ]; then
            echo "Creating systemd service for replica"
            sudo tee /etc/systemd/system/postgresql-replica.service > /dev/null <<EOF
[Unit]
Description=PostgreSQL Read Replica
After=network.target postgresql.service

[Service]
Type=notify
User=postgres
Group=postgres
ExecStart=/usr/lib/postgresql/$PG_VERSION/bin/postgres -D /var/lib/postgresql/$PG_VERSION/replica
ExecReload=/bin/kill -HUP \$MAINPID
TimeoutSec=300

[Install]
WantedBy=multi-user.target
EOF

            sudo systemctl daemon-reload
            sudo systemctl enable postgresql-replica
        fi
        
        echo "Starting postgres-replica service"
        sudo systemctl restart postgresql-replica
        sudo systemctl status postgresql-replica --no-pager
        echo "Success on read replica creation"
    fi
    echo ""
done

echo "Exited successfully."