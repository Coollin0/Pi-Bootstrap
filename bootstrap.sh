#!/usr/bin/env bash
set -euo pipefail

# =========================
#   PARAMETER / DEFAULTS
# =========================
AUTH_KEY=""                # Tailscale Auth Key (optional)
TENANT="default"           # Mieter/Kunde (Tagging)
API_BASE=""                # HQ-API Base URL (optional für Enrollment/Heartbeat)
COMPOSE_REPO=""            # Git-Repo mit docker-compose.yml
GIT_REF="main"             # Branch/Tag
CHANNEL="stable"           # rollout-channel
DEVICE_HOST_PREFIX="edge"  # Hostname-Präfix
ENABLE_TAILSCALE="1"       # 1=installieren/verbinden wenn AUTH_KEY gesetzt
ENABLE_FIREWALL="1"
ENABLE_WATCHTOWER="1"
HEARTBEAT_CRON="*/5 * * * *"  # alle 5 Minuten
TIMEZONE="Europe/Berlin"
LOCALE="de_DE.UTF-8"

usage() {
  cat <<EOF
Usage: sudo $0 [--auth-key TS_KEY] [--tenant NAME] [--api URL] [--compose GIT_URL] [--git-ref REF] [--channel stable|beta]
       [--no-tailscale] [--no-firewall] [--no-watchtower] [--tz Europe/Berlin] [--locale de_DE.UTF-8]

Beispiele:
  sudo $0 --auth-key tskey-abc --tenant kunde1 --api https://hq.example.com/api \\
          --compose https://github.com/org/prod-stack.git --git-ref main
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --auth-key)     AUTH_KEY="${2:-}"; shift 2;;
    --tenant)       TENANT="${2:-}"; shift 2;;
    --api)          API_BASE="${2:-}"; shift 2;;
    --compose)      COMPOSE_REPO="${2:-}"; shift 2;;
    --git-ref)      GIT_REF="${2:-}"; shift 2;;
    --channel)      CHANNEL="${2:-}"; shift 2;;
    --no-tailscale) ENABLE_TAILSCALE="0"; shift 1;;
    --no-firewall)  ENABLE_FIREWALL="0"; shift 1;;
    --no-watchtower) ENABLE_WATCHTOWER="0"; shift 1;;
    --tz)           TIMEZONE="${2:-}"; shift 2;;
    --locale)       LOCALE="${2:-}"; shift 2;;
    -h|--help)      usage; exit 0;;
    *) echo "Unbekannter Parameter: $1"; usage; exit 1;;
  esac
done

if [[ $EUID -ne 0 ]]; then
  echo "Bitte mit sudo/root ausführen."
  exit 1
fi

# =========================
#   DEVICE METADATA
# =========================
SERIAL="$(awk -F: '/Serial/ {print $2}' /proc/cpuinfo | xargs || true)"
DEVICE_ID="${SERIAL:-"pi-$(tr -dc a-z0-9 </dev/urandom | head -c8)"}"
HOSTNAME="${DEVICE_HOST_PREFIX}-${DEVICE_ID}"

# =========================
#   PRE-FLIGHT HARDENING
#   (dein Snippet, leicht erweitert/robust)
# =========================
echo "[1/8] System-Preflight & Hardening…"

export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y raspi-config unattended-upgrades haveged rng-tools curl ca-certificates gnupg lsb-release jq git ufw watchdog

dpkg-reconfigure -fnoninteractive unattended-upgrades || true
apt-get -y full-upgrade
rpi-eeprom-update -a || true

# Headless-Optimierung
raspi-config nonint do_change_locale "${LOCALE}"
raspi-config nonint do_change_timezone "${TIMEZONE}"
raspi-config nonint do_hostname "${HOSTNAME}"
raspi-config nonint do_ssh 0
raspi-config nonint do_i2c 0

# HDMI & BT optional aus (Server-Mode)
CFG="/boot/firmware/config.txt"
grep -q "^dtoverlay=disable-bt" "$CFG" || echo "dtoverlay=disable-bt" >> "$CFG"
grep -q "^hdmi_blanking" "$CFG" || echo "hdmi_blanking=2" >> "$CFG"

# Schreiblast reduzieren (nur hinzufügen falls nicht vorhanden)
grep -qE "^[^#]* /var/log tmpfs" /etc/fstab || echo "tmpfs /var/log tmpfs defaults,noatime,nosuid,size=100m 0 0" >> /etc/fstab
grep -qE "^[^#]* /tmp tmpfs" /etc/fstab     || echo "tmpfs /tmp     tmpfs defaults,noatime,nosuid,size=100m 0 0" >> /etc/fstab
sed -i 's/^#\?SystemMaxUse.*/SystemMaxUse=50M/' /etc/systemd/journald.conf || true
systemctl restart systemd-journald || true

# Watchdog
sed -i 's/^#\?RuntimeWatchdogSec.*/RuntimeWatchdogSec=20s/' /etc/systemd/system.conf
systemctl enable --now watchdog || true

# Firewall
if [[ "$ENABLE_FIREWALL" == "1" ]]; then
  ufw default deny incoming
  ufw allow 22/tcp
  ufw allow 53
  ufw allow 80,443/tcp
  ufw --force enable
fi

# =========================
#   DOCKER INSTALL
# =========================
echo "[2/8] Docker installieren…"
if ! command -v docker >/dev/null 2>&1; then
  curl -fsSL https://get.docker.com | sh
fi
systemctl enable --now docker

# =========================
#   TAILSCALE (optional)
# =========================
if [[ "$ENABLE_TAILSCALE" == "1" ]]; then
  echo "[3/8] Tailscale installieren…"
  if ! command -v tailscale >/dev/null 2>&1; then
    curl -fsSL https://tailscale.com/install.sh | sh
  fi
  if [[ -n "$AUTH_KEY" ]]; then
    echo "[3/8] Tailscale verbinden…"
    tailscale up --auth-key "${AUTH_KEY}" --hostname "${HOSTNAME}" --ssh --advertise-tags="tenant:${TENANT},channel:${CHANNEL}" || true
  else
    echo "[3/8] Hinweis: Kein --auth-key angegeben. 'tailscale up' kann später manuell erfolgen."
  fi
fi

# =========================
#   ENROLLMENT (optional)
# =========================
DEVICE_ENV=""
if [[ -n "$API_BASE" ]]; then
  echo "[4/8] Enrollment bei HQ (${API_BASE})…"
  ENROLL_PAYLOAD=$(jq -n \
    --arg id "$DEVICE_ID" \
    --arg serial "$SERIAL" \
    --arg tenant "$TENANT" \
    --arg channel "$CHANNEL" \
    --arg hostname "$HOSTNAME" \
    '{
      device_id:$id, serial:$serial, tenant:$tenant, channel:$channel, hostname:$hostname
    }')
  # POST /enroll → erwartet { device_env: "...", compose_url?: "...", git_ref?: "..." }
  ENROLL_RESP="$(curl -fsS -X POST "${API_BASE}/enroll" -H "Content-Type: application/json" -d "${ENROLL_PAYLOAD}" || true)"
  if [[ -n "$ENROLL_RESP" ]]; then
    DEVICE_ENV="$(echo "$ENROLL_RESP" | jq -r '.device_env // empty')"
    ENROLL_COMPOSE="$(echo "$ENROLL_RESP" | jq -r '.compose_url // empty')"
    ENROLL_REF="$(echo "$ENROLL_RESP" | jq -r '.git_ref // empty')"
    [[ -n "$ENROLL_COMPOSE" ]] && COMPOSE_REPO="$ENROLL_COMPOSE"
    [[ -n "$ENROLL_REF" ]] && GIT_REF="$ENROLL_REF"
  else
    echo "WARN: Enrollment fehlgeschlagen oder keine Antwort."
  fi
fi

# =========================
#   COMPOSE-STACK LADEN
# =========================
echo "[5/8] Compose-Stack beziehen…"
mkdir -p /opt/product
cd /opt/product

if [[ -d compose ]]; then rm -rf compose; fi
if [[ -n "$COMPOSE_REPO" ]]; then
  git clone --depth=1 --branch "$GIT_REF" "$COMPOSE_REPO" compose
else
  echo "HINWEIS: Kein --compose Repo angegeben – lege Minimal-Compose an."
  mkdir -p compose
  cat > compose/docker-compose.yml <<'YAML'
services:
  pihole:
    image: pihole/pihole:2025.07.0
    container_name: pihole
    environment:
      TZ: "Europe/Berlin"
      WEBPASSWORD: ${PIHOLE_WEBPASSWORD}
      FTLCONF_LOCAL_IPV4: ${LAN_IP}
      DNSMASQ_LISTENING: "all"
      PIHOLE_DNS_: "127.0.0.1#5335"
    volumes:
      - ./pihole/etc-pihole:/etc/pihole
      - ./pihole/etc-dnsmasq.d:/etc/dnsmasq.d
    dns:
      - 127.0.0.1
      - 1.1.1.1
    ports:
      - "53:53/tcp"
      - "53:53/udp"
      - "80:80/tcp"
    restart: unless-stopped
    labels: ["com.centurylinklabs.watchtower.enable=true"]

  unbound:
    image: mvance/unbound:1.20
    container_name: unbound
    volumes:
      - ./unbound/unbound.conf:/opt/unbound/etc/unbound/unbound.conf:ro
    ports:
      - "5335:5335/udp"
    restart: unless-stopped
    labels: ["com.centurylinklabs.watchtower.enable=true"]
YAML

  mkdir -p compose/unbound
  cat > compose/unbound/unbound.conf <<'CONF'
server:
  verbosity: 0
  interface: 0.0.0.0
  port: 5335
  do-ip4: yes
  do-udp: yes
  do-tcp: yes
  prefer-ip6: no
  harden-glue: yes
  harden-dnssec-stripped: yes
  use-caps-for-id: yes
  edns-buffer-size: 1232
  prefetch: yes
  rrset-cache-size: 100m
  msg-cache-size: 50m
  so-rcvbuf: 1m
  cache-min-ttl: 3600
  cache-max-ttl: 86400
  hide-identity: yes
  hide-version: yes
forward-zone:
  name: "."
  forward-tls-upstream: no
  forward-addr: 1.1.1.1@53
  forward-addr: 8.8.8.8@53
CONF
fi

# .env schreiben
echo "[6/8] Gerätekonfiguration anwenden…"
cat > .env <<ENV
DEVICE_ID=${DEVICE_ID}
TENANT=${TENANT}
CHANNEL=${CHANNEL}
LAN_IP=$(hostname -I | awk '{print $1}')
PIHOLE_WEBPASSWORD=$(tr -dc A-Za-z0-9 </dev/urandom | head -c 16)
ENV

# Falls vom HQ zusätzliche Variablen geliefert wurden, anhängen
if [[ -n "$DEVICE_ENV" ]]; then
  echo "" >> .env
  echo "# From HQ API" >> .env
  echo "$DEVICE_ENV" >> .env
fi

# =========================
#   STACK STARTEN
# =========================
echo "[7/8] Dienste starten…"
docker compose -f compose/docker-compose.yml --env-file .env up -d

# WATCHTOWER (Auto-Updates)
if [[ "$ENABLE_WATCHTOWER" == "1" ]]; then
  docker rm -f watchtower >/dev/null 2>&1 || true
  docker run -d --name watchtower \
    -v /var/run/docker.sock:/var/run/docker.sock \
    containrrr/watchtower \
    --cleanup --label-enable --include-stopped \
    --schedule "0 0 3 * * *"
fi

# =========================
#   HEARTBEAT (optional)
# =========================
echo "[8/8] Heartbeat einrichten…"
if [[ -n "$API_BASE" ]]; then
  cat >/usr/local/bin/edge-heartbeat.sh <<'HB'
#!/usr/bin/env bash
set -euo pipefail
API_BASE="__API_BASE__"
DEVICE_ID="__DEVICE_ID__"
HOSTNAME="__HOSTNAME__"
curl -fsS -m 5 -X POST "${API_BASE}/heartbeat" -H "Content-Type: application/json" \
  -d "{\"device_id\":\"${DEVICE_ID}\",\"hostname\":\"${HOSTNAME}\",\"ts\":\"$(date -Is)\"}" >/dev/null || true
HB
  sed -i "s#__API_BASE__#${API_BASE}#g; s#__DEVICE_ID__#${DEVICE_ID}#g; s#__HOSTNAME__#${HOSTNAME}#g" /usr/local/bin/edge-heartbeat.sh
  chmod +x /usr/local/bin/edge-heartbeat.sh
  ( crontab -l 2>/dev/null; echo "${HEARTBEAT_CRON} /usr/local/bin/edge-heartbeat.sh" ) | crontab -
else
  echo "Kein --api angegeben: Überspringe Heartbeat."
fi

echo
echo "======================================================="
echo "✓ Fertig! Hostname: ${HOSTNAME}"
echo "   LAN IP: $(hostname -I | awk '{print $1}')"
if command -v tailscale >/dev/null 2>&1; then
  echo "   Tailscale: $(tailscale ip -4 2>/dev/null | head -n1 || echo 'nicht verbunden')"
fi
echo "   Pi-hole Web: http://$(hostname -I | awk '{print $1}')/admin"
echo "   WEBPASSWORD steht in /opt/product/.env (PIHOLE_WEBPASSWORD)"
echo "======================================================="
