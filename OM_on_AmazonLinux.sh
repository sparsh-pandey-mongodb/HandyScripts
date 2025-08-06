#!/bin/bash
# ============================================================================
# MongoDB Ops Manager Automated Setup Script (Amazon Linux, EC2)
# ----------------------------------------------------------------------------
#  - Provisions standalone AppDB (mongod) for Ops Manager metadata
#  - Installs MongoDB Enterprise and Ops Manager with all config/dependency prep
#  - Implements '--cleanup' for safe, idempotent teardown
#  - Waits for Ops Manager UI to be available 
#  - USAGE: sudo ./setup_ops_manager.sh [--cleanup]
# ----------------------------------------------------------------------------

set -euo pipefail

##### --- USER PARAMETERS: OVERRIDE VIA ENV VARS WHEN CALLING SCRIPT --- #####
MONGO_VERSION="${MONGO_VERSION:-8.0.10}" # MongoDB Enterprise version to install
OM_VERSION="${OM_VERSION:-8.0.8.500.20250604T1500Z}" # Ops Manager version to install

##### --- OTHER PARAMETERS --- #####
MONGO_USER="mongod"
APP_DB_PORT=27017
APP_DB_PATH="/data/appdb"
APP_DB_LOG="/data/appdb/mongodb.log"
APP_DB_CONF="/etc/mongod.conf"
APP_DB_PID="/var/run/mongodb/mongod.pid"

OM_RPM="mongodb-mms-${OM_VERSION}.x86_64.rpm"
OM_URL="https://downloads.mongodb.com/on-prem-mms/rpm/$OM_RPM"
OM_CONF="/opt/mongodb/mms/conf/conf-mms.properties"
MONGODB_REPO="/etc/yum.repos.d/mongodb-enterprise-8.0.repo"

# --- Always use localhost/127.0.0.1 for all access checks and UI ---
LOCALHOST="127.0.0.1"

##### --- CLEANUP MODE --- #####
if [[ "${1:-}" == "--cleanup" ]]; then
  echo "==== Stopping Ops Manager and AppDB, Removing All Files and Host Aliases ===="

  # Stop mongod if running on the AppDB port
  pid=$(sudo lsof -t -iTCP:$APP_DB_PORT -sTCP:LISTEN || true)
  if [[ -n "$pid" ]]; then
    echo "Killing mongod on port $APP_DB_PORT (pid $pid)..."
    sudo kill "$pid"
    sleep 2
  fi

  # Stop Ops Manager service
  echo "Stopping Ops Manager (if running)..."
  sudo systemctl stop mongodb-mms 2>/dev/null || true

  # Remove data, config, agent configs and local RPMs
  echo "Removing AppDB data and config..."
  sudo rm -rf "$APP_DB_PATH" "$APP_DB_CONF" || true
  echo "Removing previously downloaded Ops Manager RPM and config..."
  sudo rm -f "$OM_CONF" "$OM_RPM"
  sudo rm -rf /opt/mongodb

  if rpm -q mongodb-mms >/dev/null 2>&1; then
    sudo yum remove -y mongodb-mms || true
  fi
  if [[ -f "$MONGODB_REPO" ]]; then
    sudo rm -f "$MONGODB_REPO"
  fi

  echo "==== Cleanup complete. Ops Manager and AppDB are removed. ===="
  exit 0
fi

##### --- MONGODB ENTERPRISE INSTALL --- #####
if ! command -v mongod >/dev/null 2>&1; then
  echo "MongoDB not detected -- installing MongoDB Enterprise $MONGO_VERSION ..."
  sudo tee "$MONGODB_REPO" >/dev/null <<EOF
[mongodb-enterprise-8.0]
name=MongoDB Enterprise Repository
# Official RPM repository for MongoDB Enterprise Server
baseurl=https://repo.mongodb.com/yum/amazon/2023/mongodb-enterprise/8.0/\$basearch/
gpgcheck=1
enabled=1
gpgkey=https://pgp.mongodb.com/server-8.0.asc
EOF
  sudo yum install -y \
    "mongodb-enterprise-${MONGO_VERSION}" \
    "mongodb-enterprise-database-${MONGO_VERSION}" \
    "mongodb-enterprise-server-${MONGO_VERSION}" \
    "mongodb-mongosh" \
    "mongodb-enterprise-mongos-${MONGO_VERSION}" \
    "mongodb-enterprise-tools-${MONGO_VERSION}" \
    "mongodb-enterprise-cryptd-${MONGO_VERSION}" \
    "mongodb-enterprise-database-tools-extra-${MONGO_VERSION}"
fi

# Confirm mongod and mongosh are available (will fail the script if not)
if ! command -v mongod >/dev/null 2>&1 || ! command -v mongosh >/dev/null 2>&1; then
  echo "ERROR: mongod or mongosh CLI not found after package install, aborting!"
  exit 2
fi

##### --- APPDB Directory Preparation --- #####
echo "Preparing /data/appdb and /var/run/mongodb, ensuring correct ownership for mongod user..."
sudo mkdir -p /var/run/mongodb
sudo chown $MONGO_USER:$MONGO_USER /var/run/mongodb
sudo mkdir -p "$APP_DB_PATH"
sudo chown -R $MONGO_USER:$MONGO_USER "$APP_DB_PATH"

##### --- APPDB mongod CONFIGURATION --- #####
# The mongod config written below is annotated with YAML comments for clarity.
if [[ ! -f "$APP_DB_CONF" ]]; then
  echo "Writing initial AppDB mongod config (with inline YAML comments) to $APP_DB_CONF ..."
cat <<EOF | sudo tee "$APP_DB_CONF" >/dev/null
# ----------------------------------------------------------------------------
# mongod configuration for Ops Manager Application Database (AppDB)
#   - Standalone localhost-only instance for Ops Manager metadata
#   - Accessible on 127.0.0.1:$APP_DB_PORT
#
# Documentation: https://www.mongodb.com/docs/ops-manager/current/tutorial/install-simple-test-deployment/
# ----------------------------------------------------------------------------
systemLog:
  destination: file            # Log to disk file
  path: $APP_DB_LOG            # Log file location
  logAppend: true              # Append mode (no overwrite)
storage:
  dbPath: $APP_DB_PATH         # Directory for database files
  wiredTiger:
    engineConfig:
      cacheSizeGB: 5           # WiredTiger cache size 
processManagement:
  fork: true                   # Fork process to run mongod in background (so script can progress)
  timeZoneInfo: /usr/share/zoneinfo # For correct time zone support
  pidFilePath: $APP_DB_PID     # PID file location
net:
  bindIp: 127.0.0.1            # Bind to localhost (Ops Manager runs on same host)
  port: $APP_DB_PORT           # Port for connections
setParameter:
  enableLocalhostAuthBypass: false # Disable localhost exception (recommended for test/prod)
EOF
fi

##### --- APPDB mongod STARTUP --- #####
echo "Checking if AppDB mongod is already running on $APP_DB_PORT ..."
if sudo lsof -iTCP:"$APP_DB_PORT" -sTCP:LISTEN >/dev/null 2>&1; then
  echo "AppDB mongod is already running on port $APP_DB_PORT"
else
  echo "Starting AppDB mongod instance in background (using --fork)..."
  sudo -u $MONGO_USER mongod --config "$APP_DB_CONF" --fork --logpath "$APP_DB_LOG"
  sleep 3
  if sudo lsof -iTCP:"$APP_DB_PORT" -sTCP:LISTEN >/dev/null 2>&1; then
    echo "App DB mongod started successfully."
  else
    echo "ERROR: mongod did not start! Check $APP_DB_LOG for error details."
    exit 1
  fi
fi

##### --- OPS MANAGER INSTALLATION --- #####
if ! rpm -q mongodb-mms >/dev/null 2>&1; then
  echo "Downloading MongoDB Ops Manager RPM from $OM_URL ..."
  if [[ ! -f "$OM_RPM" ]]; then
    curl -O "$OM_URL"
  fi
  echo "Installing Ops Manager RPM..."
  sudo rpm -ivh "$OM_RPM"
fi

echo "Restarting and enabling Ops Manager systemd service..."
sudo systemctl restart mongodb-mms
sudo systemctl enable mongodb-mms


##### --- WAIT FOR OPS MANAGER UI (8080) --- #####
echo -n "Waiting for Ops Manager UI to become available "
ATTEMPTS=0
MAX_ATTEMPTS=60 # 3 min (3 sec * 60)

# UI check: accept HTTP 200, 303 or a valid HTML title
function check_ui_local() {
  # Try to connect, check for HTTP/1.1, HTML title, HTTP 200 or 303 (redirect is fine)
  local code
  code="$(curl -s --connect-timeout 2 --max-time 3 -o /dev/null -w "%{http_code}" "http://localhost:8080")"
  if [[ "$code" = "200" || "$code" = "303" ]]; then
    return 0
  fi
  # Some basic HTML title match for insurance
  if curl -s -L --connect-timeout 2 --max-time 3 "http://localhost:8080" | grep -qi "<title>.*(Ops Manager|MongoDB Ops Manager|Log in|Login)</title>"; then
    return 0
  fi
  return 1
}

while true; do
  ATTEMPTS=$((ATTEMPTS+1))
  if check_ui_local; then
    echo "at http://localhost:8080 ... Ready!"
    break
  fi
  if [[ $ATTEMPTS -ge $MAX_ATTEMPTS ]]; then
    echo
    echo "ERROR: Ops Manager UI did not come up within $((MAX_ATTEMPTS*3/60)) minutes."
    echo "       Check: sudo systemctl status mongodb-mms"
    echo "       Logs:  /opt/mongodb/mms/logs/"
    exit 5
  fi
  sleep 3
  echo -n "."
done

##### --- PRINT --- #####
echo
echo "============================================================"
echo " MongoDB Ops Manager is now fully installed and running!"
echo " UI login:   PUBLIC IP or localhost on port 8080"
echo " AppDB port: 127.0.0.1:27017 (standalone metadata store)"
echo " To cleanup: sudo $0 --cleanup"
echo
echo "Conf file:      $APP_DB_CONF (see YAML comments!)"
echo "Ops Manager conf: $OM_CONF"
echo "============================================================"
