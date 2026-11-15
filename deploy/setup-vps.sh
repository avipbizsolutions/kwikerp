#!/usr/bin/env bash
# KwikERP API on an Ubuntu 24.04 + CloudPanel VPS.
# Safe to run again: the same script installs the first time and updates afterwards.
# Run as root:   bash deploy/setup-vps.sh
#
# What it adds (and nothing else on the server is touched):
#   - PostgreSQL 16 from Ubuntu's own packages, listening on localhost only
#   - system user "kwikerp", files under /opt/kwikerp, its own Node.js in /opt/kwikerp/node
#   - secrets in /etc/kwikerp/api.env, generated here, never stored in git
#   - systemd service "kwikerp-api" on 127.0.0.1:$PORT
#   - a CloudPanel reverse-proxy site for $DOMAIN with a Let's Encrypt certificate
#   - the tablet app at https://$DOMAIN/api/download/pos.apk
set -euo pipefail

DOMAIN=${DOMAIN:-api.kwikerp.cloud}
PORT=${PORT:-3100}
REPO=${REPO:-https://github.com/avipbizsolutions/kwikerp.git}
NODE_VER=${NODE_VER:-v22.21.1}
BASE=/opt/kwikerp
ENV_FILE=/etc/kwikerp/api.env
as_app() { sudo -u kwikerp env HOME=$BASE PATH=$BASE/node/bin:/usr/bin:/bin "$@"; }
step() { echo; echo "== $*"; }

step "Checks"
[ "$(id -u)" = 0 ] || { echo "Run as root"; exit 1; }
if ss -ltnH "sport = :$PORT" | grep -q . && ! systemctl is-active --quiet kwikerp-api; then
  echo "Port $PORT is used by another program. Re-run with PORT=<free port>."; exit 1
fi

step "PostgreSQL 16"
if ! dpkg -s postgresql-16 >/dev/null 2>&1; then
  apt-get update -q && DEBIAN_FRONTEND=noninteractive apt-get install -yq postgresql-16
fi
systemctl enable --now postgresql >/dev/null

step "User and folders"
id kwikerp >/dev/null 2>&1 || useradd --system --home-dir $BASE --shell /usr/sbin/nologin kwikerp
mkdir -p $BASE/downloads /etc/kwikerp
chown kwikerp:kwikerp $BASE $BASE/downloads

step "Node.js $NODE_VER (private copy, does not change the server's own Node)"
if [ "$(as_app node -v 2>/dev/null || true)" != "$NODE_VER" ]; then
  rm -rf $BASE/node $BASE/node-$NODE_VER-linux-x64
  curl -fsSL https://nodejs.org/dist/$NODE_VER/node-$NODE_VER-linux-x64.tar.xz | tar -xJ -C $BASE
  mv $BASE/node-$NODE_VER-linux-x64 $BASE/node
  chown -R kwikerp:kwikerp $BASE/node
fi

step "Code"
if [ -d $BASE/src/.git ]; then
  as_app git -C $BASE/src fetch -q origin main
  as_app git -C $BASE/src reset -q --hard origin/main
else
  as_app git clone -q "$REPO" $BASE/src
fi
as_app git -C $BASE/src log -1 --format='%h %s'

step "Secrets"
if [ ! -f $ENV_FILE ]; then
  umask 027
  cat > $ENV_FILE <<EOF
PORT=$PORT
DATABASE_URL=postgres://kwik_api:$(openssl rand -hex 24)@127.0.0.1:5432/kwikerp
JWT_SECRET=$(openssl rand -hex 32)
APPROVAL_SECRET=$(openssl rand -hex 32)
DOWNLOAD_DIR=$BASE/downloads
EOF
  umask 022
  chown root:kwikerp $ENV_FILE
  chmod 640 $ENV_FILE
  echo "Created $ENV_FILE"
fi
DB_PASS=$(sed -n 's#^DATABASE_URL=postgres://kwik_api:\([^@]*\)@.*#\1#p' $ENV_FILE)

step "Database"
pg() { sudo -u postgres psql -X -v ON_ERROR_STOP=1 -q "$@"; }
pg -tAc "SELECT 1 FROM pg_database WHERE datname = 'kwikerp'" | grep -q 1 || sudo -u postgres createdb kwikerp
pg -d kwikerp -c "CREATE TABLE IF NOT EXISTS public.kwik_migrations (name text PRIMARY KEY, applied_at timestamptz NOT NULL DEFAULT now())"
cd $BASE/src
for f in db/migrations/*.sql db/seed/0001_troika_setup.sql db/seed/0002_troika_items.sql; do
  if ! pg -d kwikerp -tAc "SELECT 1 FROM public.kwik_migrations WHERE name = '$f'" | grep -q 1; then
    echo "Applying $f"
    pg -d kwikerp -f "$f"
    pg -d kwikerp -c "INSERT INTO public.kwik_migrations (name) VALUES ('$f')"
  fi
done
pg -d kwikerp <<SQL
DO \$\$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'kwik_api') THEN
    CREATE ROLE kwik_api LOGIN IN ROLE kwik_app;
  END IF;
END \$\$;
ALTER ROLE kwik_api PASSWORD '$DB_PASS';
SQL

step "Build API"
cd $BASE/src/apps/api
as_app npm ci --no-audit --no-fund --loglevel=error
as_app npm run build --silent

step "Service"
cat > /etc/systemd/system/kwikerp-api.service <<EOF
[Unit]
Description=KwikERP API
After=network.target postgresql.service

[Service]
User=kwikerp
WorkingDirectory=$BASE/src/apps/api
EnvironmentFile=$ENV_FILE
ExecStart=$BASE/node/bin/node dist/main.js
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable kwikerp-api >/dev/null
systemctl restart kwikerp-api
for i in $(seq 1 20); do curl -fsS http://127.0.0.1:$PORT/api/health >/dev/null 2>&1 && break; sleep 1; done
curl -fsS http://127.0.0.1:$PORT/api/health && echo

step "Tablet app file"
if as_app git -C $BASE/src fetch -q origin apk 2>/dev/null; then
  as_app sh -c "git -C $BASE/src show FETCH_HEAD:kwikerp-pos.apk > $BASE/downloads/kwikerp-pos.apk"
  ls -lh $BASE/downloads/kwikerp-pos.apk
else
  echo "No app build published yet (branch 'apk')"
fi

step "Web address $DOMAIN (CloudPanel)"
if ! ls /etc/nginx/sites-enabled/ | grep -q "^$DOMAIN.conf$"; then
  clpctl site:add:reverse-proxy --domainName=$DOMAIN --reverseProxyUrl=http://127.0.0.1:$PORT \
    --siteUser=kwikapi --siteUserPassword="$(openssl rand -hex 16)"
fi
# CloudPanel starts a new site on a self-signed certificate; replace it with Let's Encrypt.
if ! openssl x509 -in /etc/nginx/ssl-certificates/$DOMAIN.crt -noout -issuer 2>/dev/null | grep -q "Let's Encrypt"; then
  clpctl lets-encrypt:install:certificate --domainName=$DOMAIN || echo "Certificate not issued yet (DNS may still be spreading); run this script again in a few minutes."
fi

step "Done"
curl -fsS https://$DOMAIN/api/health && echo || echo "HTTPS check failed"
echo "Tablet app: https://$DOMAIN/api/download/pos.apk"
