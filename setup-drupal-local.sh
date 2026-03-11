#!/usr/bin/env bash
set -Eeuo pipefail

# ==============================================================================
# One-shot Drupal local full-stack container setup
# - Traefik (HTTP) -> Nginx -> Drupal 10 (FPM)
# - ProxySQL -> MariaDB primary/replica (GTID)
# - Redis (AUTH) mandatory + enforced in Drupal
# - Prometheus + Grafana + Loki + node_exporter + cAdvisor
# - Daily logical backups
# - Auto Drupal install via Drush
# - Composer retry/backoff + persistent Composer cache volume
# - Generates Makefile with: open / health / tail / etc.
#
# Usage:
#   ./setup-drupal-local.sh [--check-ports] [--add-hosts] [--ports <spec>] [domain]
#
# Examples:
#   ./setup-drupal-local.sh --check-ports --add-hosts drupal.local
#   ./setup-drupal-local.sh --ports web=8081,traefik=8082,grafana=3300,prometheus=9091,loki=3101
#   ./setup-drupal-local.sh --ports 8081,8082,3300,9091,3101
#
# Options:
#   --check-ports   Check required ports are free before starting (silent on success).
#   --add-hosts     Add 127.0.0.1 <domain> to /etc/hosts if missing (requires sudo).
#   --ports SPEC    Override host ports. SPEC formats:
#                    - CSV order: web,traefik,grafana,prometheus,loki
#                      e.g. --ports 8081,8082,3300,9091,3101
#                    - Key=val pairs (comma-separated): web=,traefik=,grafana=,prometheus=,loki=
#                      e.g. --ports web=8081,traefik=8082,grafana=3300,prometheus=9091,loki=3101
#   -h|--help       Show help.
#
# Notes:
# - Requires: docker + docker compose (Compose v2 plugin), openssl.
# - Recommended: make (for Makefile shortcuts).
# ==============================================================================

PROJECT="drupal-platform"

# Fixed per request (local/dev)
SITE_NAME="drupal.local"
ADMIN_USER="drupallocaladmin"
ADMIN_PASS="drupallocaladminpass"
ADMIN_MAIL="admin@example.com"

CHECK_PORTS="false"
ADD_HOSTS="false"
DOMAIN="drupal.local"

# Default host port bindings
PORT_WEB=80
PORT_TRAEFIK_DASH=8080
PORT_GRAFANA=3000
PORT_PROMETHEUS=9090
PORT_LOKI=3100

usage() {
  sed -n '1,120p' "$0" | sed 's/^# \{0,1\}//'
}

is_port() {
  [[ "$1" =~ ^[0-9]+$ ]] && ((1 <= $1 && $1 <= 65535))
}

parse_ports_spec() {
  local spec="$1"
  if [[ "$spec" == *"="* ]]; then
    IFS=',' read -r -a pairs <<< "$spec"
    for kv in "${pairs[@]}"; do
      local key="${kv%%=*}"
      local val="${kv#*=}"
      key="${key,,}"
      if ! is_port "$val"; then
        echo "[FATAL] Invalid port value for ${key}: ${val}" >&2
        exit 1
      fi
      case "$key" in
        web) PORT_WEB="$val";;
        traefik|traefik_dash|dashboard) PORT_TRAEFIK_DASH="$val";;
        grafana) PORT_GRAFANA="$val";;
        prometheus|prom) PORT_PROMETHEUS="$val";;
        loki) PORT_LOKI="$val";;
        *)
          echo "[FATAL] Unknown port key in --ports: ${key}" >&2
          exit 1
          ;;
      esac
    done
  else
    IFS=',' read -r pweb ptraefik pgraf pprom ploki <<< "$spec"
    if [[ -z "${ploki:-}" ]]; then
      echo "[FATAL] --ports CSV must provide 5 comma-separated values: web,traefik,grafana,prometheus,loki" >&2
      exit 1
    fi
    for p in "$pweb" "$ptraefik" "$pgraf" "$pprom" "$ploki"; do
      if ! is_port "$p"; then
        echo "[FATAL] Invalid port in --ports CSV: ${p}" >&2
        exit 1
      fi
    done
    PORT_WEB="$pweb"
    PORT_TRAEFIK_DASH="$ptraefik"
    PORT_GRAFANA="$pgraf"
    PORT_PROMETHEUS="$pprom"
    PORT_LOKI="$ploki"
  fi

  python3 - <<PY
ports = [int("$PORT_WEB"), int("$PORT_TRAEFIK_DASH"), int("$PORT_GRAFANA"), int("$PORT_PROMETHEUS"), int("$PORT_LOKI")]
if len(set(ports)) != len(ports):
    raise SystemExit("[FATAL] --ports contains duplicate host ports; choose unique ports.")
PY
}

# Parse args
while [[ $# -gt 0 ]]; do
  case "$1" in
    --check-ports) CHECK_PORTS="true"; shift ;;
    --add-hosts) ADD_HOSTS="true"; shift ;;
    --ports)
      [[ $# -ge 2 ]] || { echo "[FATAL] --ports requires a value" >&2; exit 1; }
      parse_ports_spec "$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    --) shift; break ;;
    -*) echo "[FATAL] Unknown option: $1" >&2; usage; exit 1 ;;
    *) DOMAIN="$1"; shift ;;
  esac
done

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "[FATAL] Missing required command: $1" >&2
    exit 1
  }
}

need_cmd openssl
need_cmd docker

if ! docker compose version >/dev/null 2>&1; then
  echo "[FATAL] 'docker compose' not available. Install Docker Compose v2 plugin." >&2
  exit 1
fi

if ! command -v make >/dev/null 2>&1; then
  echo "[WARN] 'make' not found. You can still use docker compose, but Makefile shortcuts won't work." >&2
fi

rand_hex() { openssl rand -hex 16; }

# --check-ports (silent on success)
port_in_use() {
  local port="$1"
  if command -v ss >/dev/null 2>&1; then
    ss -lnt 2>/dev/null | awk '{print $4}' | grep -Eq "(^|:)${port}$" && return 0 || return 1
  fi
  if command -v lsof >/dev/null 2>&1; then
    lsof -iTCP:"${port}" -sTCP:LISTEN >/dev/null 2>&1 && return 0 || return 1
  fi
  if command -v netstat >/dev/null 2>&1; then
    netstat -lnt 2>/dev/null | awk '{print $4}' | grep -Eq "(^|:)${port}$" && return 0 || return 1
  fi
  echo "[WARN] Cannot check ports (ss/lsof/netstat missing). Skipping." >&2
  return 1
}

if [[ "$CHECK_PORTS" == "true" ]]; then
  REQ_PORTS=($PORT_WEB $PORT_TRAEFIK_DASH $PORT_GRAFANA $PORT_PROMETHEUS $PORT_LOKI)
  USED=0
  for p in "${REQ_PORTS[@]}"; do
    if port_in_use "$p"; then
      echo "[ERROR] Port $p appears to be in use. Stop the conflicting service or override ports with --ports." >&2
      USED=1
    fi
  done
  if [[ "$USED" -ne 0 ]]; then
    echo "[FATAL] Port check failed." >&2
    exit 1
  fi
fi

# --add-hosts
add_hosts_entry() {
  local domain="$1"
  local hosts_file="/etc/hosts"

  if [[ "$domain" == "localhost" || "$domain" == "127.0.0.1" ]]; then
    return 0
  fi

  if grep -Eq "^[[:space:]]*127\\.0\\.0\\.1[[:space:]]+.*\\b${domain}\\b" "$hosts_file" 2>/dev/null; then
    return 0
  fi

  local line="127.0.0.1 ${domain}"
  if [[ $(id -u) -eq 0 ]]; then
    echo "$line" >> "$hosts_file"
  else
    need_cmd sudo
    echo "$line" | sudo tee -a "$hosts_file" >/dev/null
  fi

  echo "[OK] Added /etc/hosts: $line"
}

if [[ "$ADD_HOSTS" == "true" ]]; then
  add_hosts_entry "$DOMAIN"
fi

# Create project structure
echo "==> Creating project directory: ${PROJECT}"
mkdir -p "${PROJECT}"/{nginx,traefik,proxysql,monitoring,backups,db/init,db/replica-init,drupal}
cd "${PROJECT}"

# .env
ENV_FILE=".env"
if [[ -f "${ENV_FILE}" ]]; then
  echo "==> Found existing .env; reusing."
else
  echo "==> Creating .env (secrets + install parameters)"
  DB_ROOT_PASS="$(rand_hex)"
  DB_USER="drupal"
  DB_PASS="$(rand_hex)"
  DB_NAME="drupal"

  REPL_USER="repl"
  REPL_PASS="$(rand_hex)"

  REDIS_PASS="$(rand_hex)"

  cat > "${ENV_FILE}" <<EOF
DOMAIN=${DOMAIN}
SITE_NAME=${SITE_NAME}
ADMIN_USER=${ADMIN_USER}
ADMIN_PASS=${ADMIN_PASS}
ADMIN_MAIL=${ADMIN_MAIL}
DB_ROOT_PASS=${DB_ROOT_PASS}
DB_USER=${DB_USER}
DB_PASS=${DB_PASS}
DB_NAME=${DB_NAME}
REPL_USER=${REPL_USER}
REPL_PASS=${REPL_PASS}
REDIS_PASS=${REDIS_PASS}
COMPOSER_CACHE_DIR=/composer-cache
COMPOSER_RETRY_MAX=6
COMPOSER_RETRY_BASE_SLEEP=2
COMPOSER_RETRY_MAX_SLEEP=60
COMPOSER_PROCESS_TIMEOUT=600
EOF
  chmod 600 "${ENV_FILE}"
fi

# shellcheck disable=SC1090
source "${ENV_FILE}"

# Drupal image
cat > drupal/Dockerfile <<'EOF'
FROM drupal:10-fpm

RUN set -eux; \
  apt-get update; \
  apt-get install -y --no-install-recommends \
    ca-certificates curl git unzip \
    mariadb-client netcat-openbsd \
    autoconf gcc g++ make pkg-config; \
  rm -rf /var/lib/apt/lists/*

RUN set -eux; \
  pecl install redis; \
  docker-php-ext-enable redis

RUN set -eux; \
  curl -fsSL https://getcomposer.org/installer | php -- --install-dir=/usr/local/bin --filename=composer; \
  composer --version
EOF

# Installer
cat > drupal/install.sh <<'EOF'
#!/usr/bin/env sh
set -eu

cd /var/www/html

: "${COMPOSER_CACHE_DIR:=/composer-cache}"
export COMPOSER_CACHE_DIR
mkdir -p "${COMPOSER_CACHE_DIR}" || true

: "${COMPOSER_RETRY_MAX:=6}"
: "${COMPOSER_RETRY_BASE_SLEEP:=2}"
: "${COMPOSER_RETRY_MAX_SLEEP:=60}"
: "${COMPOSER_PROCESS_TIMEOUT:=600}"
export COMPOSER_PROCESS_TIMEOUT

composer_retry() {
  i=1
  while [ "$i" -le "$COMPOSER_RETRY_MAX" ]; do
    echo "[composer] Attempt $i/$COMPOSER_RETRY_MAX: composer $*"

    set +e
    composer -n "$@"
    rc=$?
    set -e

    if [ "$rc" -eq 0 ]; then
      return 0
    fi

    if [ "$i" -eq "$COMPOSER_RETRY_MAX" ]; then
      echo "[composer][FATAL] Failed after $COMPOSER_RETRY_MAX attempts: composer $*" >&2
      return "$rc"
    fi

    backoff=$((COMPOSER_RETRY_BASE_SLEEP * (2 ** (i - 1))))
    if [ "$backoff" -gt "$COMPOSER_RETRY_MAX_SLEEP" ]; then
      backoff="$COMPOSER_RETRY_MAX_SLEEP"
    fi

    jitter=$(( $(od -An -N1 -tu1 /dev/urandom | tr -d ' ') % 3 ))
    sleep_for=$((backoff + jitter))

    if [ "$i" -ge 3 ]; then
      echo "[composer] Clearing cache before retry..."
      composer clear-cache >/dev/null 2>&1 || true
    fi

    echo "[composer] Retry in ${sleep_for}s..."
    sleep "$sleep_for"
    i=$((i + 1))
  done

  return 1
}

echo "[installer] Waiting for ProxySQL (proxysql:6033) ..."
until nc -z proxysql 6033; do sleep 2; done

echo "[installer] Waiting for Redis (redis:6379) ..."
until nc -z redis 6379; do sleep 2; done

php -r 'exit(extension_loaded("redis") ? 0 : 1);' || {
  echo "[installer][FATAL] PHP redis extension not loaded." >&2
  exit 1
}

ALREADY_INSTALLED=false
if [ -f "sites/default/settings.php" ]; then
  ALREADY_INSTALLED=true
fi

mkdir -p sites/default/files
chmod -R 777 sites/default || true

if [ ! -x "vendor/bin/drush" ]; then
  composer_retry require drush/drush
fi
DRUSH="./vendor/bin/drush"

if [ "$ALREADY_INSTALLED" = "false" ]; then
  echo "[installer] Running Drupal install via Drush..."
  "$DRUSH" -y --root=/var/www/html --uri="http://${DOMAIN}" site:install standard \
    --db-url="mysql://${DB_USER}:${DB_PASS}@proxysql:6033/${DB_NAME}" \
    --site-name="${SITE_NAME}" \
    --account-name="${ADMIN_USER}" \
    --account-pass="${ADMIN_PASS}" \
    --account-mail="${ADMIN_MAIL}" \
    --site-mail="${ADMIN_MAIL}"
else
  echo "[installer] Existing Drupal detected; skipping site:install but enforcing Redis." 
fi

composer_retry require drupal/redis
"$DRUSH" -y en redis

SETTINGS="sites/default/settings.php"
if ! grep -q "REDIS_SETTINGS_BEGIN" "$SETTINGS"; then
  cat >> "$SETTINGS" <<'SNIP'

# REDIS_SETTINGS_BEGIN
$settings['redis.connection']['interface'] = 'PhpRedis';
$settings['redis.connection']['host'] = 'redis';
$settings['redis.connection']['password'] = getenv('REDIS_PASS');
$settings['cache']['default'] = 'cache.backend.redis';
# REDIS_SETTINGS_END
SNIP
fi

php -r '
$h=getenv("REDIS_HOST") ?: "redis";
$p=(int)(getenv("REDIS_PORT") ?: 6379);
$pass=getenv("REDIS_PASS");
$r=new Redis();
if(!$r->connect($h,$p,2.0)) {fwrite(STDERR,"connect failed\n"); exit(1);} 
if($pass && !$r->auth($pass)) {fwrite(STDERR,"auth failed\n"); exit(1);} 
$ping=$r->ping();
if($ping !== "+PONG" && $ping !== true) {fwrite(STDERR,"ping failed\n"); exit(1);} 
echo "OK\n";
'

echo "[installer] ✅ Redis integration enforced successfully."
EOF
chmod +x drupal/install.sh

# Nginx
cat > nginx/default.conf <<'EOF'
server {
  listen 80;
  server_name _;
  root /var/www/html;
  index index.php index.html;
  client_max_body_size 64M;

  location / {
    try_files $uri /index.php?$query_string;
  }

  location ~ \.php$ {
    include fastcgi_params;
    fastcgi_pass drupal:9000;
    fastcgi_param SCRIPT_FILENAME $document_root$fastcgi_script_name;
    fastcgi_read_timeout 300;
  }

  location ~ /\.(?!well-known).* {
    deny all;
  }
}
EOF

# Replication init
cat > db/init/001-create-repl-user.sql <<EOF
CREATE USER IF NOT EXISTS '${REPL_USER}'@'%' IDENTIFIED BY '${REPL_PASS}';
GRANT REPLICATION SLAVE ON *.* TO '${REPL_USER}'@'%';
FLUSH PRIVILEGES;
EOF

cat > db/replica-init/010-configure-replication.sh <<'EOF'
#!/bin/sh
set -eu
until mariadb-admin ping -h db_primary -uroot -p"${DB_ROOT_PASS}" --silent; do
  sleep 2
done
mariadb -uroot -p"${DB_ROOT_PASS}" <<SQL
STOP SLAVE;
RESET SLAVE ALL;
CHANGE MASTER TO
  MASTER_HOST='db_primary',
  MASTER_USER='${REPL_USER}',
  MASTER_PASSWORD='${REPL_PASS}',
  MASTER_USE_GTID=slave_pos;
START SLAVE;
SQL
EOF
chmod +x db/replica-init/010-configure-replication.sh

# ProxySQL
cat > proxysql/proxysql.cnf <<EOF
datadir="/var/lib/proxysql"
admin_variables={ admin_credentials="admin:admin" mysql_ifaces="0.0.0.0:6032" }
mysql_variables={ threads=2 max_connections=1024 interfaces="0.0.0.0:6033" default_schema="${DB_NAME}" }
mysql_servers=(
  { address="db_primary" , port=3306 , hostgroup=10 , max_connections=500 }
  { address="db_replica" , port=3306 , hostgroup=20 , max_connections=500 }
)
mysql_users=(
  { username="${DB_USER}" , password="${DB_PASS}" , default_hostgroup=10 , active=1 }
)
mysql_replication_hostgroups=(
  { writer_hostgroup=10 , reader_hostgroup=20 , comment="primary/replica" }
)
EOF

# Prometheus
cat > monitoring/prometheus.yml <<'EOF'
global:
  scrape_interval: 15s
scrape_configs:
  - job_name: 'node'
    static_configs:
      - targets: ['node_exporter:9100']
  - job_name: 'cadvisor'
    static_configs:
      - targets: ['cadvisor:8080']
EOF

# docker-compose.yml with port overrides
cat > docker-compose.yml <<EOF
version: "3.9"
services:
  traefik:
    image: traefik:v3
    command:
      - "--providers.docker=true"
      - "--providers.docker.exposedbydefault=false"
      - "--entrypoints.web.address=:80"
      - "--api.dashboard=true"
    ports:
      - "${PORT_WEB}:80"
      - "127.0.0.1:${PORT_TRAEFIK_DASH}:8080"
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock:ro
    restart: unless-stopped
    networks: [edge]

  nginx:
    image: nginx:stable
    env_file: .env
    volumes:
      - ./nginx/default.conf:/etc/nginx/conf.d/default.conf:ro
      - drupal_data:/var/www/html
    depends_on: [drupal]
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.drupal.rule=Host(\`${DOMAIN}\`) || Host(\`localhost\`)"
      - "traefik.http.routers.drupal.entrypoints=web"
      - "traefik.http.services.drupal.loadbalancer.server.port=80"
    restart: unless-stopped
    networks: [edge, internal]

  drupal:
    build: ./drupal
    env_file: .env
    environment:
      DRUPAL_DB_HOST: proxysql
      DRUPAL_DB_NAME: ${DB_NAME}
      DRUPAL_DB_USER: ${DB_USER}
      DRUPAL_DB_PASSWORD: ${DB_PASS}
      REDIS_HOST: redis
      REDIS_PORT: "6379"
      REDIS_PASS: ${REDIS_PASS}
      COMPOSER_CACHE_DIR: /composer-cache
    volumes:
      - drupal_data:/var/www/html
      - composer_cache:/composer-cache
    restart: unless-stopped
    networks: [internal]

  drupal_installer:
    build: ./drupal
    env_file: .env
    environment:
      COMPOSER_CACHE_DIR: /composer-cache
    depends_on:
      - proxysql
      - redis
      - drupal
    volumes:
      - drupal_data:/var/www/html
      - composer_cache:/composer-cache
      - ./drupal/install.sh:/usr/local/bin/install.sh:ro
    entrypoint: ["/bin/sh", "/usr/local/bin/install.sh"]
    user: "0:0"
    restart: "no"
    networks: [internal]

  proxysql:
    image: proxysql/proxysql:2.6
    volumes:
      - ./proxysql/proxysql.cnf:/etc/proxysql.cnf:ro
      - proxysql_data:/var/lib/proxysql
    depends_on: [db_primary, db_replica]
    restart: unless-stopped
    networks: [internal]

  db_primary:
    image: mariadb:11
    env_file: .env
    command: ["--server-id=1","--log-bin=mysql-bin","--binlog-format=ROW","--gtid-strict-mode=ON","--enforce-gtid-consistency=ON","--log-slave-updates=ON"]
    environment:
      MYSQL_ROOT_PASSWORD: ${DB_ROOT_PASS}
      MYSQL_DATABASE: ${DB_NAME}
      MYSQL_USER: ${DB_USER}
      MYSQL_PASSWORD: ${DB_PASS}
    volumes:
      - db_primary:/var/lib/mysql
      - ./db/init:/docker-entrypoint-initdb.d:ro
    restart: unless-stopped
    networks: [internal]
    healthcheck:
      test: ["CMD","mariadb-admin","ping","-uroot","-p${DB_ROOT_PASS}"]
      interval: 10s
      timeout: 5s
      retries: 10

  db_replica:
    image: mariadb:11
    env_file: .env
    command: ["--server-id=2","--read-only=ON","--gtid-strict-mode=ON","--enforce-gtid-consistency=ON","--log-slave-updates=ON"]
    environment:
      MYSQL_ROOT_PASSWORD: ${DB_ROOT_PASS}
    volumes:
      - db_replica:/var/lib/mysql
      - ./db/replica-init:/docker-entrypoint-initdb.d:ro
    depends_on:
      db_primary:
        condition: service_healthy
    restart: unless-stopped
    networks: [internal]

  redis:
    image: redis:7
    env_file: .env
    command: ["redis-server","--requirepass","${REDIS_PASS}"]
    volumes:
      - redis_data:/data
    restart: unless-stopped
    networks: [internal]
    healthcheck:
      test: ["CMD","redis-cli","-a","${REDIS_PASS}","PING"]
      interval: 10s
      timeout: 3s
      retries: 15

  prometheus:
    image: prom/prometheus
    volumes:
      - ./monitoring/prometheus.yml:/etc/prometheus/prometheus.yml:ro
    ports:
      - "127.0.0.1:${PORT_PROMETHEUS}:9090"
    restart: unless-stopped
    networks: [internal]

  grafana:
    image: grafana/grafana
    ports:
      - "127.0.0.1:${PORT_GRAFANA}:3000"
    volumes:
      - grafana_data:/var/lib/grafana
    restart: unless-stopped
    networks: [internal]

  loki:
    image: grafana/loki:2.9.5
    ports:
      - "127.0.0.1:${PORT_LOKI}:3100"
    restart: unless-stopped
    networks: [internal]

  node_exporter:
    image: prom/node-exporter
    restart: unless-stopped
    networks: [internal]

  cadvisor:
    image: gcr.io/cadvisor/cadvisor:v0.49.1
    restart: unless-stopped
    networks: [internal]
    volumes:
      - /:/rootfs:ro
      - /var/run:/var/run:ro
      - /sys:/sys:ro
      - /var/lib/docker/:/var/lib/docker:ro

  backup:
    image: mariadb:11
    env_file: .env
    depends_on:
      db_primary:
        condition: service_healthy
    volumes:
      - ./backups:/backup
    entrypoint: /bin/sh
    command: -c '
      set -eu; mkdir -p /backup;
      while true; do
        TS=$(date +%F_%H%M%S);
        OUT="/backup/${DB_NAME}_${TS}.sql.gz";
        mariadb-dump -h db_primary -u root -p"${DB_ROOT_PASS}" --single-transaction --routines --events --databases "${DB_NAME}" | gzip > "$OUT";
        ls -1t /backup/${DB_NAME}_*.sql.gz | tail -n +8 | xargs -r rm -f;
        sleep 86400;
      done'
    restart: unless-stopped
    networks: [internal]

networks:
  edge:
  internal:
    internal: true

volumes:
  drupal_data:
  db_primary:
  db_replica:
  redis_data:
  grafana_data:
  proxysql_data:
  composer_cache:
EOF

# Makefile (ports aware)
cat > Makefile <<EOF
COMPOSE ?= docker compose
DRUPAL_SCALE ?= 1
PORT_WEB ?= ${PORT_WEB}
PORT_TRAEFIK_DASH ?= ${PORT_TRAEFIK_DASH}
PORT_GRAFANA ?= ${PORT_GRAFANA}
PORT_PROMETHEUS ?= ${PORT_PROMETHEUS}
PORT_LOKI ?= ${PORT_LOKI}

.PHONY: help up down ps logs installer-logs tail open health drush scale env urls nuke

help:
	@awk 'BEGIN {FS=":.*##"} /^[a-zA-Z0-9_\-]+:.*##/ {printf "\033[36m%-18s\033[0m %s\n", \$\$1, \$\$2}' \$(MAKEFILE_LIST)

up: ## Build (if needed) and start the stack
	\$(COMPOSE) up -d --build

down: ## Stop and remove containers (keep volumes)
	\$(COMPOSE) down

ps: ## Show container status
	\$(COMPOSE) ps

logs: ## Tail logs for all services
	\$(COMPOSE) logs -f --tail=200

installer-logs: ## Tail logs for the one-shot Drupal installer
	\$(COMPOSE) logs -f --tail=300 drupal_installer

tail: ## Tail logs for one service (usage: make tail SERVICE=nginx)
	@test -n "\$(SERVICE)" || (echo "Provide SERVICE" && exit 1)
	\$(COMPOSE) logs -f --tail=200 \$(SERVICE)

open: ## Open Drupal in your default browser
	@URL="http://\$\$(. ./.env 2>/dev/null; echo \$\${DOMAIN:-localhost}):\$(PORT_WEB)"; \
	echo "Opening \$\$URL ..."; \
	command -v xdg-open >/dev/null 2>&1 && xdg-open "\$\$URL" >/dev/null 2>&1 & || true

health: ## Quick health checks
	@set -e; . ./.env 2>/dev/null || true; \
	\$(COMPOSE) exec -T db_primary mariadb-admin ping -uroot -p"\$\${DB_ROOT_PASS}" --silent; \
	\$(COMPOSE) exec -T redis redis-cli -a "\$\${REDIS_PASS}" PING | grep -q PONG; \
	\$(COMPOSE) exec -T nginx nginx -t >/dev/null 2>&1; \
	echo "OK"

drush: ## Run a Drush command (usage: make drush CMD="status")
	@test -n "\$(CMD)" || (echo "Provide CMD" && exit 1)
	\$(COMPOSE) exec -T drupal /var/www/html/vendor/bin/drush \$(CMD)

scale: ## Scale Drupal FPM (usage: make scale DRUPAL_SCALE=3)
	\$(COMPOSE) up -d --scale drupal=\$(DRUPAL_SCALE)

env: ## Show .env
	@sed -n '1,200p' ./.env

urls: ## Print URLs
	@DOMAIN=\$\$(. ./.env 2>/dev/null; echo \$\${DOMAIN:-drupal.local}); \
	echo "Drupal: http://localhost:\$(PORT_WEB) (or http://\$\$DOMAIN:\$(PORT_WEB))"; \
	echo "Traefik: http://127.0.0.1:\$(PORT_TRAEFIK_DASH)"; \
	echo "Grafana: http://127.0.0.1:\$(PORT_GRAFANA)"; \
	echo "Prometheus: http://127.0.0.1:\$(PORT_PROMETHEUS)"; \
	echo "Loki: http://127.0.0.1:\$(PORT_LOKI)"

nuke: ## Tear down EVERYTHING (containers + volumes)
	\$(COMPOSE) down -v
EOF

echo "==> Starting stack (build + up)"
docker compose up -d --build

echo ""
echo "Drupal: http://localhost:${PORT_WEB} (or http://${DOMAIN}:${PORT_WEB})"
echo "Traefik UI: http://127.0.0.1:${PORT_TRAEFIK_DASH}"
echo "Grafana: http://127.0.0.1:${PORT_GRAFANA}"
echo "Prometheus: http://127.0.0.1:${PORT_PROMETHEUS}"
echo "Loki: http://127.0.0.1:${PORT_LOKI}"
