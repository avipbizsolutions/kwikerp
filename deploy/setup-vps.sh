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
#   - a timer (kwikerp-autoupdate) that runs this script again whenever GitHub has
#     new code or a new app build, so updates need no terminal
#   - the tablet app at https://$DOMAIN/api/download/pos.apk
#     re-signed with this server's own key (/etc/kwikerp/pos-signing.jks) so tablets can update
#     without uninstalling. BACK UP that key: without it, tablets must uninstall to update.
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
for f in db/migrations/*.sql db/seed/*.sql; do
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
# GitHub builds the app with a throw-away key. Every copy served from here is
# re-signed with one permanent key, so a newer app installs over an older one.
dpkg -s apksigner >/dev/null 2>&1 || DEBIAN_FRONTEND=noninteractive apt-get install -yq apksigner
KS=/etc/kwikerp/pos-signing.jks
KS_PASS_FILE=/etc/kwikerp/pos-signing.pass
if [ ! -f $KS ]; then
  umask 077
  openssl rand -hex 24 > $KS_PASS_FILE
  keytool -genkeypair -keystore $KS -storetype PKCS12 -alias kwikerp-pos -keyalg RSA -keysize 4096 -validity 10000 \
    -storepass:file $KS_PASS_FILE -dname "CN=KwikERP POS, O=AVIP Business Solutions LLP, C=IN" >/dev/null 2>&1
  umask 022
  echo "Created app signing key $KS. Copy $KS and $KS_PASS_FILE somewhere safe."
fi
if as_app git -C $BASE/src fetch -q origin apk 2>/dev/null; then
  TMP=$(mktemp -d)
  as_app git -C $BASE/src show FETCH_HEAD:kwikerp-pos.apk > $TMP/in.apk
  apksigner sign --ks $KS --ks-key-alias kwikerp-pos --ks-pass file:$KS_PASS_FILE --out $TMP/out.apk $TMP/in.apk
  apksigner verify $TMP/out.apk
  install -o kwikerp -g kwikerp -m 644 $TMP/out.apk $BASE/downloads/kwikerp-pos.apk
  # Version last, so tablets are only told to update once the new file is in place.
  as_app git -C $BASE/src show FETCH_HEAD:kwikerp-pos.json > $TMP/v.json 2>/dev/null \
    && install -o kwikerp -g kwikerp -m 644 $TMP/v.json $BASE/downloads/kwikerp-pos.json \
    && echo "App version: $(cat $BASE/downloads/kwikerp-pos.json)"
  rm -rf $TMP
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

step "Automatic updates"
# Every 5 minutes: if GitHub's main branch (code) or apk branch (tablet app) has
# moved, run the newest copy of this script. Logs: journalctl -u kwikerp-autoupdate
mkdir -p /var/lib/kwikerp
cat > /usr/local/sbin/kwikerp-autoupdate <<'EOS'
#!/usr/bin/env bash
set -euo pipefail
exec 9>/run/kwikerp-autoupdate.lock
flock -n 9 || exit 0
SRC=/opt/kwikerp/src
STATE=/var/lib/kwikerp/deployed-refs
git_app() { sudo -u kwikerp env HOME=/opt/kwikerp git -C $SRC "$@"; }
now=$(git_app ls-remote origin refs/heads/main refs/heads/apk 2>/dev/null | awk '{print $1}' | tr '\n' ' ' || true)
[ -n "$now" ] || { echo "GitHub not reachable"; exit 0; }
[ "$now" = "$(cat $STATE 2>/dev/null || true)" ] && exit 0
echo "New code or app build on GitHub: updating"
git_app fetch -q origin main
tmp=$(mktemp)
git_app show FETCH_HEAD:deploy/setup-vps.sh > "$tmp"
if bash "$tmp"; then
  echo "$now" > $STATE
  echo "Update finished"
else
  echo "Update FAILED; will retry in 5 minutes"
fi
rm -f "$tmp"
EOS
chmod 755 /usr/local/sbin/kwikerp-autoupdate
cat > /etc/systemd/system/kwikerp-autoupdate.service <<'EOS'
[Unit]
Description=Update KwikERP from GitHub when there is something new
After=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/kwikerp-autoupdate
EOS
cat > /etc/systemd/system/kwikerp-autoupdate.timer <<'EOS'
[Unit]
Description=Check GitHub for KwikERP updates every 5 minutes

[Timer]
OnBootSec=2min
OnUnitActiveSec=5min

[Install]
WantedBy=timers.target
EOS
systemctl daemon-reload
systemctl enable --now kwikerp-autoupdate.timer >/dev/null
# This run is itself up to date
as_app git -C $BASE/src ls-remote origin refs/heads/main refs/heads/apk | awk '{print $1}' | tr '\n' ' ' > /var/lib/kwikerp/deployed-refs || true
echo "Checks GitHub every 5 minutes. Log: journalctl -u kwikerp-autoupdate"

step "Done"
curl -fsS https://$DOMAIN/api/health && echo || echo "HTTPS check failed"
echo "Tablet app: https://$DOMAIN/api/download/pos.apk"
