#!/usr/bin/env bash

set -Eeuo pipefail

PRIMARY_PORT=5432
REPLICA_PORT=5433

PG_MAJOR=""
PG_PACKAGE=""
PG_BIN=""
PGROOT=""
PGDATA=""
PG_SERVICE=""
REPLICA_DATA=""
REPLICA_SERVICE=""

log() {
  echo -e "\n[INFO] $1"
}

success() {
  echo -e "\n[OK] $1"
}

error() {
  echo -e "\n[ERROR] $1" >&2
}

if [[ "$EUID" -ne 0 ]]; then
  echo "[ERROR] Run using sudo: sudo ./sv-based.sh"
  exit 1
fi
install_postgres() {

  log "Checking XBPS repositories..."

  xbps-install -S

  log "Checking installed PostgreSQL server..."

  local installed

  installed=$(
    xbps-query -l |
      awk '{print $2}' |
      grep -E '^postgresql[0-9]+-[0-9]' |
      sed -E 's/-[0-9].*$//' |
      sort -Vu |
      tail -n1 || true
  )

  if [[ -n "$installed" ]]; then

    PG_PACKAGE="$installed"
    success "Found installed server: $PG_PACKAGE"

  else

    log "PostgreSQL server not found. Searching repositories..."
    local available
    available=$(
      xbps-query -Rs postgresql |
        awk '$2 ~ /^postgresql[0-9]+-[0-9]/ {
                package=$2
                sub(/-[0-9].*/, "", package)
                print package
            }' |
        sort -Vu |
        tail -n1
    )

    if [[ -z "$available" ]]; then
      error "No PostgreSQL server package found."
      return 1
    fi

    PG_PACKAGE="$available"
    log "Installing $PG_PACKAGE..."
    xbps-install -y "$PG_PACKAGE"

  fi

  PG_MAJOR="${PG_PACKAGE#postgresql}"
  PG_BIN="/usr/lib/pgsql${PG_MAJOR}/bin"
  PG_SERVICE="$PG_PACKAGE"
  log "Checking PostgreSQL client..."
  if [[ ! -x "$PG_BIN/psql" ]]; then
    log "Installing matching PostgreSQL client..."

    xbps-install -y "${PG_PACKAGE}-client"

  else

    success "Matching PostgreSQL client already exists."

  fi

  for binary in postgres psql pg_basebackup pg_ctl; do

    if [[ ! -x "$PG_BIN/$binary" ]]; then
      error "$binary not found in $PG_BIN"
      return 1
    fi

  done
  export PATH="$PG_BIN:$PATH"
  success "PostgreSQL installation verified."
  echo "Server: $("$PG_BIN/postgres" --version)"
  echo "Client: $("$PG_BIN/psql" --version)"
  local defaults="/etc/psql${PG_MAJOR}/default/postgresql"

  if [[ ! -f "$defaults" ]]; then
    error "PostgreSQL defaults file not found: $defaults"
    return 1
  fi

  source "$defaults"
  PGROOT="${PGROOT:-/var/lib/postgresql${PG_MAJOR}}"
  PGDATA="${PGDATA:-$PGROOT/data}"

  REPLICA_DATA="$PGROOT/replica"
  REPLICA_SERVICE="${PG_SERVICE}-replica"

  success "PostgreSQL paths detected."

  echo "Version:       $PG_MAJOR"
  echo "Binary:        $PG_BIN"
  echo "Primary data:  $PGDATA"
  echo "Replica data:  $REPLICA_DATA"
  echo "Service:       $PG_SERVICE"
}

start_primary() {

  log "Checking primary PostgreSQL service..."

  if [[ ! -d "/etc/sv/$PG_SERVICE" ]]; then
    error "Primary runit service not found."
    return 1
  fi

  if [[ ! -L "/var/service/$PG_SERVICE" ]]; then
    log "Enabling primary runit service..."

    ln -s "/etc/sv/$PG_SERVICE" "/var/service/$PG_SERVICE"

  fi

  sv up "$PG_SERVICE"

  log "Waiting for primary database..."

  local attempts=0

  until "$PG_BIN/pg_isready" -h 127.0.0.1 -p "$PRIMARY_PORT" >/dev/null 2>&1; do

    attempts=$((attempts + 1))

    if [[ "$attempts" -ge 30 ]]; then
      error "Primary PostgreSQL did not become ready."
      return 1
    fi

    sleep 2

  done

  success "Primary PostgreSQL is accepting connections."
}
postgres_sql() {

  su -s /bin/sh postgres -c \
    "\"$PG_BIN/psql\" -p $PRIMARY_PORT -d postgres -v ON_ERROR_STOP=1 -c \"\$1\"" \
    sh "$1"
}

configure_primary() {
  log "Configuring primary database..."
  read -r -p "Replication username [replicator]: " REPL_USER
  REPL_USER="${REPL_USER:-replicator}"

  if [[ ! "$REPL_USER" =~ ^[a-zA-Z_][a-zA-Z0-9_]*$ ]]; then
    error "Invalid replication username."
    return 1
  fi

  read -r -s -p "Replication password: " REPL_PASSWORD
  echo

  if [[ -z "$REPL_PASSWORD" ||
    "$REPL_PASSWORD" == *$'\n'* ||
    "$REPL_PASSWORD" == *$'\r'* ]]; then
    error "Invalid replication password."
    return 1
  fi
  log "Creating replication user..."

  local escaped_password
  escaped_password=${REPL_PASSWORD//\'/\'\'}
  local role_exists

  role_exists=$(
    su -s /bin/sh postgres -c \
      "\"$PG_BIN/psql\" -p $PRIMARY_PORT -d postgres -Atqc \"SELECT 1 FROM pg_roles WHERE rolname='$REPL_USER'\""
  )

  if [[ "$role_exists" == "1" ]]; then

    postgres_sql \
      "ALTER ROLE $REPL_USER WITH LOGIN REPLICATION PASSWORD '$escaped_password';"

  else

    postgres_sql \
      "CREATE ROLE $REPL_USER WITH LOGIN REPLICATION PASSWORD '$escaped_password';"

  fi

  log "Setting replication parameters..."

  postgres_sql "ALTER SYSTEM SET wal_level = 'replica';"
  postgres_sql "ALTER SYSTEM SET max_wal_senders = 10;"
  postgres_sql "ALTER SYSTEM SET wal_keep_size = '512MB';"
  postgres_sql "ALTER SYSTEM SET listen_addresses = '127.0.0.1';"

  log "Configuring pg_hba.conf..."

  local HBA="$PGDATA/pg_hba.conf"

  if [[ ! -f "$HBA" ]]; then
    error "Primary pg_hba.conf not found."
    return 1
  fi

  local hba_rule="host replication $REPL_USER 127.0.0.1/32 scram-sha-256"

  if ! grep -Fxq "$hba_rule" "$HBA"; then

    echo "$hba_rule" >>"$HBA"

  fi

  chown postgres:postgres "$HBA"
  log "Restarting primary PostgreSQL..."
  sv restart "$PG_SERVICE"

  sleep 3

  "$PG_BIN/pg_isready" -h 127.0.0.1 -p "$PRIMARY_PORT"

  success "Primary replication configuration completed."
}

create_replica() {

  log "Starting replica creation process..."

  if [[ -z "${REPL_USER:-}" || -z "${REPL_PASSWORD:-}" ]]; then
    error "Configure the primary replication user first."
    return 1
  fi
  if [[ -L "/var/service/$REPLICA_SERVICE" ]]; then

    log "Stopping existing replica service..."

    sv down "$REPLICA_SERVICE" || true

  fi

  if [[ -d "$REPLICA_DATA" ]]; then

    echo
    echo "[WARNING] Existing replica data directory found:"
    echo "$REPLICA_DATA"

    read -r -p "Delete and recreate this replica? (yes/no): " answer

    if [[ "$answer" != "yes" ]]; then
      log "Replica creation cancelled."
      return 1
    fi

    rm -rf -- "$REPLICA_DATA"

  fi

  mkdir -p "$REPLICA_DATA"
  chown postgres:postgres "$REPLICA_DATA"
  chmod 700 "$REPLICA_DATA"

  log "Running pg_basebackup..."

  export PGPASSWORD="$REPL_PASSWORD"

  if ! "$PG_BIN/pg_basebackup" \
    -h 127.0.0.1 \
    -p "$PRIMARY_PORT" \
    -U "$REPL_USER" \
    -D "$REPLICA_DATA" \
    -Fp \
    -P \
    -R \
    -X stream; then

    unset PGPASSWORD

    error "pg_basebackup failed."
    return 1

  fi

  unset PGPASSWORD
  if [[ ! -f "$REPLICA_DATA/PG_VERSION" ||
    ! -f "$REPLICA_DATA/standby.signal" ]]; then

    error "Replica integrity check failed."
    return 1

  fi

  success "Base backup completed."
  log "Configuring replica PostgreSQL..."

  cat >>"$REPLICA_DATA/postgresql.conf" <<EOF

port = $REPLICA_PORT
listen_addresses = '127.0.0.1'
hot_standby = on

EOF

  local POSTGRES_HOME

  POSTGRES_HOME=$(awk -F: '$1=="postgres" {print $6}' /etc/passwd)

  if [[ -z "$POSTGRES_HOME" || ! -d "$POSTGRES_HOME" ]]; then
    error "Cannot locate postgres user's home directory."
    return 1
  fi

  local pgpass_user="$REPL_USER"
  local pgpass_password="$REPL_PASSWORD"

  pgpass_user=${pgpass_user//\\/\\\\}
  pgpass_user=${pgpass_user//:/\\:}

  pgpass_password=${pgpass_password//\\/\\\\}
  pgpass_password=${pgpass_password//:/\\:}

  touch "$POSTGRES_HOME/.pgpass"

  local pgpass_entry="127.0.0.1:$PRIMARY_PORT:replication:$pgpass_user:$pgpass_password"

  if ! grep -Fqx "$pgpass_entry" "$POSTGRES_HOME/.pgpass"; then
    echo "$pgpass_entry" >>"$POSTGRES_HOME/.pgpass"
  fi

  chown postgres:postgres "$POSTGRES_HOME/.pgpass"
  chmod 600 "$POSTGRES_HOME/.pgpass"
  chown -R postgres:postgres "$REPLICA_DATA"
  chmod 700 "$REPLICA_DATA"

  log "Creating runit service..."

  local SERVICE_DIR="/etc/sv/$REPLICA_SERVICE"

  mkdir -p "$SERVICE_DIR"

  cat >"$SERVICE_DIR/run" <<EOF
#!/bin/sh

exec chpst -u postgres:postgres "$PG_BIN/postgres" -D "$REPLICA_DATA"
EOF

  chmod +x "$SERVICE_DIR/run"
  if [[ ! -L "/var/service/$REPLICA_SERVICE" ]]; then

    ln -s "$SERVICE_DIR" "/var/service/$REPLICA_SERVICE"

  fi
  log "Starting PostgreSQL replica..."

  sv up "$REPLICA_SERVICE"
  local attempts=0

  until "$PG_BIN/pg_isready" -h 127.0.0.1 -p "$REPLICA_PORT" >/dev/null 2>&1; do

    attempts=$((attempts + 1))

    if [[ "$attempts" -ge 30 ]]; then
      error "Replica failed to start. Check runit logs."
      return 1
    fi

    sleep 2

  done

  success "Replica service started."
  local recovery

  recovery=$(
    su -s /bin/sh postgres -c \
      "\"$PG_BIN/psql\" -h 127.0.0.1 -p $REPLICA_PORT -d postgres -Atqc 'SELECT pg_is_in_recovery();'"
  )

  if [[ "$recovery" != "t" ]]; then

    error "Replica is not in recovery mode."
    return 1

  fi

  success "PostgreSQL read replica created successfully!"

  echo
  echo "Primary port: $PRIMARY_PORT"
  echo "Replica port: $REPLICA_PORT"
  echo "Replica directory: $REPLICA_DATA"

  unset REPL_PASSWORD
}

check_replica() {

  log "Checking replica status..."

  if ! "$PG_BIN/pg_isready" -h 127.0.0.1 -p "$REPLICA_PORT"; then

    error "Replica is not accepting connections."
    return 1

  fi

  su -s /bin/sh postgres -c \
    "\"$PG_BIN/psql\" -h 127.0.0.1 -p $REPLICA_PORT -d postgres -c 'SELECT pg_is_in_recovery();'"

  echo
  log "Checking primary replication connections..."

  su -s /bin/sh postgres -c \
    "\"$PG_BIN/psql\" -p $PRIMARY_PORT -d postgres -c 'SELECT client_addr, state, sync_state FROM pg_stat_replication;'"
}

main() {

  echo "======================================"
  echo " PostgreSQL Replica Manager"
  echo " Void Linux | runit"
  echo "======================================"

  install_postgres || exit 1

  start_primary || exit 1

  local number=-1

  while [[ "$number" -ne 0 ]]; do

    local hour
    hour=$((10#$(date +%H)))

    CURRENT_USER="${SUDO_USER:-$(whoami)}"

    echo
    echo "Hello $CURRENT_USER"

    if [[ "$hour" -lt 12 ]]; then
      echo "Good morning! Ready to work on your replica?"
    elif [[ "$hour" -lt 17 ]]; then
      echo "Good afternoon! Let's manage your replica."
    elif [[ "$hour" -lt 22 ]]; then
      echo "It's getting late pal, sip coffee as you create your replica."
    else
      echo "No sleep? Let's get everything done!"
    fi

    echo
    echo "Options:"
    echo "1. Check if replica exists"
    echo "2. Create replica"
    echo "0. Exit"

    read -r -p "Choose an option: " number

    case "$number" in

    1)
      check_replica
      ;;

    2)
      configure_primary && create_replica
      ;;

    0)
      echo "Exiting successfully."
      ;;

    *)
      echo "Invalid option."
      ;;

    esac

  done
}

main "$@"
