#!/usr/bin/env bash
set -euo pipefail

: "${PORT:=6806}"
: "${SIYUAN_INTERNAL_PORT:=6807}"
: "${SIYUAN_ACCESS_AUTH_CODE:=changeme}"
: "${SIYUAN_FLAGS:=--no-sandbox --disable-gpu --disable-software-rasterizer --disable-dev-shm-usage}"
export TZ="${TZ:-Asia/Singapore}"

# Force create DBus directories and socket with proper permissions
echo "Creating DBus directories and socket files..."
mkdir -p /run/dbus
mkdir -p /var/run/dbus
touch /run/dbus/system_bus_socket
chmod 755 /run/dbus
chmod 755 /var/run/dbus
chmod 777 /run/dbus/system_bus_socket

# Set environment variables to minimize DBus errors
export NO_AT_BRIDGE=1
export DBUS_SESSION_BUS_ADDRESS="unix:path=/tmp/dbus-dummy.socket"
export DBUS_SYSTEM_BUS_ADDRESS="unix:path=/tmp/dbus-dummy.socket"
touch /tmp/dbus-dummy.socket
chmod 777 /tmp/dbus-dummy.socket

wait_for_port() {
  local host=$1 port=$2 timeout=$3
  for ((i=0;i<timeout;i++)); do
    if (echo > /dev/tcp/$host/$port) &>/dev/null; then return 0; fi
    sleep 1
  done
  return 1
}

# Tier-0 kernel
if [ -x /opt/siyuan/kernel ]; then
  echo "[Tier-0] starting kernel binary"
  /opt/siyuan/kernel --workspace=/siyuan/workspace --accessAuthCode="${SIYUAN_ACCESS_AUTH_CODE}" --port="${SIYUAN_INTERNAL_PORT}" &
  KPID=$!
  if wait_for_port 127.0.0.1 "${SIYUAN_INTERNAL_PORT}" 20; then
    echo "[Tier-0] kernel healthy"
  else
    kill $KPID || true
    unset KPID
  fi
fi

if [ -z "${KPID:-}" ]; then
  export DISPLAY=:99
  rm -f /tmp/.X99-lock || true
  Xvfb :99 -screen 0 1280x800x24 -nolisten tcp &
  XV=$!
  
  # Add additional flags to further reduce DBus dependency
  SIYUAN_FLAGS="${SIYUAN_FLAGS} --disable-features=DBus,BlinkGenPropertyTrees,UseChromeOSDirectVideoDecoder"
  
  echo "Starting SiYuan with flags: ${SIYUAN_FLAGS}"
  /opt/siyuan/siyuan --workspace=/siyuan/workspace --accessAuthCode="${SIYUAN_ACCESS_AUTH_CODE}" --port="${SIYUAN_INTERNAL_PORT}" ${SIYUAN_FLAGS} &
  KPID=$!
  if ! wait_for_port 127.0.0.1 "${SIYUAN_INTERNAL_PORT}" 30; then
    echo "SiYuan failed to open port"
    exit 1
  fi
fi

echo "[init] kernel up on ${SIYUAN_INTERNAL_PORT}"

if [[ -n "${DISCORD_CLIENT_ID:-}" && -n "${DISCORD_CLIENT_SECRET:-}" && -n "${DISCORD_CALLBACK_URL:-}" ]]; then
  node /app/discord-auth/server.js &
  PROXY=$!
  wait $KPID $PROXY
else
  wait $KPID
fi
