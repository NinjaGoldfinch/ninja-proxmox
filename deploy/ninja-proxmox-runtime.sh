#!/usr/bin/env bash
#
# ninja-proxmox-runtime.sh
#
# Installs or refreshes the ninja-proxmox *runtime* inside the container: the
# systemd units, the ninja-proxmox CLI, the environment-file layout and the
# shell aliases. Optionally deploys the application code itself.
#
# This is the single source of truth for those files.
# provision-ninja-proxmox-lxc.sh runs it during provisioning;
# update-ninja-proxmox.sh runs it again later to pick up new code. Keeping it
# in one file is the point — the two callers cannot drift apart.
#
# It is idempotent and deliberately narrow. It touches CODE only. It never
# reads or writes:
#   * /etc/ninja-proxmox/env — your PVE token, DB password and API keys
#   * the Postgres cluster or its contents
#   * anything under /root/ on the Proxmox host
#
# RUN THIS AS ROOT INSIDE THE CONTAINER.
#
#   ./ninja-proxmox-runtime.sh [--deploy] [--migrate] [--restart]
#
# --deploy   fetch the configured ref, install dependencies and build
# --migrate  run database migrations after a successful build
# --restart  cycle ninja-proxmox.target afterwards
#
# Configuration comes from /etc/ninja-proxmox.conf (written at provision time);
# APP_USER, APP_DIR, APP_PORT, REPO_URL and REPO_REF in the environment
# override it.
#
set -Eeuo pipefail

DEPLOY=0; MIGRATE=0; RESTART=0
while [ $# -gt 0 ]; do
  case "$1" in
    --deploy)  DEPLOY=1; shift ;;
    --migrate) MIGRATE=1; shift ;;
    --restart) RESTART=1; shift ;;
    -h|--help) sed -n '2,32p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "ninja-proxmox-runtime: unknown argument: $1" >&2; exit 2 ;;
  esac
done

say() { printf '\n--- %s\n' "$*"; }
warn() { printf 'warn: %s\n' "$*" >&2; }
die() { printf 'ninja-proxmox-runtime: %s\n' "$*" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || die "run this as root inside the container"

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

CONF=/etc/ninja-proxmox.conf
if [ -r "$CONF" ]; then
  # shellcheck disable=SC1090
  . "$CONF"
fi

APP_USER="${APP_USER:-ninja}"
APP_DIR="${APP_DIR:-/opt/ninja-proxmox}"
APP_PORT="${APP_PORT:-8080}"
ENV_DIR="${ENV_DIR:-/etc/ninja-proxmox}"
ENV_FILE="${ENV_FILE:-${ENV_DIR}/env}"
REPO_URL="${REPO_URL:-https://github.com/NinjaGoldfinch/ninja-proxmox}"
REPO_REF="${REPO_REF:-main}"

id -u "$APP_USER" >/dev/null 2>&1 || die "user '${APP_USER}' does not exist"

# Record the box's settings so update-ninja-proxmox.sh needs nothing but a CTID.
cat >"$CONF" <<EOF
# Written by ninja-proxmox-runtime.sh. Safe to edit; consumed by the updater.
APP_USER='${APP_USER}'
APP_DIR='${APP_DIR}'
APP_PORT='${APP_PORT}'
ENV_DIR='${ENV_DIR}'
ENV_FILE='${ENV_FILE}'
REPO_URL='${REPO_URL}'
REPO_REF='${REPO_REF}'
EOF
chmod 644 "$CONF"

# ---------------------------------------------------------------------------
# Deploy the application code
# ---------------------------------------------------------------------------

# Whether the checkout currently contains something runnable. The repo starts
# life as a design document with no src/, so this stays honest rather than
# failing the whole provision on a build that cannot exist yet.
APP_BUILDABLE=0
APP_STATE="not-implemented"

if [ "$DEPLOY" = "1" ]; then
  say "Deploying ${REPO_URL} @ ${REPO_REF}"
  install -d -o "$APP_USER" -g "$APP_USER" -m 755 "$APP_DIR"

  if [ -d "${APP_DIR}/.git" ]; then
    sudo -u "$APP_USER" git -C "$APP_DIR" remote set-url origin "$REPO_URL"
    sudo -u "$APP_USER" git -C "$APP_DIR" fetch --depth 50 origin "$REPO_REF" \
      || die "could not fetch ${REPO_REF} from ${REPO_URL}"
    sudo -u "$APP_USER" git -C "$APP_DIR" checkout -q --detach FETCH_HEAD
  else
    sudo -u "$APP_USER" git clone --depth 50 --branch "$REPO_REF" "$REPO_URL" "$APP_DIR" \
      || die "could not clone ${REPO_URL} (${REPO_REF})"
  fi
  printf 'checked out %s\n' "$(git -C "$APP_DIR" rev-parse --short HEAD)"

  # dotenv reads ./.env; systemd reads EnvironmentFile. One file, two readers.
  if [ ! -e "${APP_DIR}/.env" ]; then
    sudo -u "$APP_USER" ln -sfn "$ENV_FILE" "${APP_DIR}/.env"
  fi

  if [ -d "${APP_DIR}/src" ] && [ -f "${APP_DIR}/package.json" ]; then
    APP_BUILDABLE=1
  else
    warn "no src/ in the checkout — ninja-proxmox is still a design document."
    warn "The box is provisioned and ready; the units will start once code lands."
  fi

  if [ "$APP_BUILDABLE" = "1" ]; then
    say "Installing dependencies"
    if [ -f "${APP_DIR}/package-lock.json" ]; then
      sudo -u "$APP_USER" npm --prefix "$APP_DIR" ci --no-audit --no-fund
    else
      sudo -u "$APP_USER" npm --prefix "$APP_DIR" install --no-audit --no-fund
    fi

    say "Building"
    if sudo -u "$APP_USER" npm --prefix "$APP_DIR" run build; then
      APP_STATE="built"
    else
      APP_STATE="build-failed"
      warn "build failed — leaving the previous dist/ in place"
    fi

    if [ "$MIGRATE" = "1" ] && [ "$APP_STATE" = "built" ]; then
      say "Migrating the database"
      if sudo -u "$APP_USER" --preserve-env=NODE_ENV \
           sh -c "cd '${APP_DIR}' && npm run migrate"; then
        :
      else
        APP_STATE="migrate-failed"
        warn "migrations failed — check ${ENV_FILE} DATABASE_URL"
      fi
    fi
  fi
fi

# ---------------------------------------------------------------------------
# systemd units
# ---------------------------------------------------------------------------

say "systemd units"

# One target so the fleet moves together, two units so the API can be bounced
# without interrupting a task follower mid-poll.
cat > /etc/systemd/system/ninja-proxmox.target <<EOF
[Unit]
Description=ninja-proxmox (API + worker)
Wants=ninja-proxmox-api.service ninja-proxmox-worker.service
After=ninja-proxmox-api.service ninja-proxmox-worker.service

[Install]
WantedBy=multi-user.target
EOF

# MemoryDenyWriteExecute is deliberately absent: it breaks V8's JIT and Node
# will not start under it. Everything else here is free.
write_unit() {
  local name="$1" desc="$2" entry="$3"
  cat > "/etc/systemd/system/ninja-proxmox-${name}.service" <<EOF
[Unit]
Description=${desc}
Documentation=https://github.com/NinjaGoldfinch/ninja-proxmox
After=network-online.target postgresql.service
Wants=network-online.target
PartOf=ninja-proxmox.target

[Service]
Type=simple
User=${APP_USER}
Group=${APP_USER}
WorkingDirectory=${APP_DIR}
EnvironmentFile=${ENV_FILE}
Environment=NODE_ENV=production
ExecStart=/usr/bin/node ${entry}
Restart=always
RestartSec=3
# A unit that flaps because the PVE token is wrong should stop and say so,
# not spin forever against the cluster.
StartLimitIntervalSec=120
StartLimitBurst=8
KillSignal=SIGTERM
TimeoutStopSec=30
NoNewPrivileges=yes
PrivateTmp=yes
PrivateDevices=yes
ProtectSystem=strict
ProtectHome=yes
ReadWritePaths=${APP_DIR}
ProtectKernelTunables=yes
ProtectKernelModules=yes
ProtectControlGroups=yes
RestrictSUIDSGID=yes
RestrictRealtime=yes
LockPersonality=yes
SystemCallArchitectures=native
UMask=0077

[Install]
WantedBy=ninja-proxmox.target
EOF
}

write_unit api    "ninja-proxmox API"    "dist/index.js"
write_unit worker "ninja-proxmox worker" "dist/worker.js"

systemctl daemon-reload
systemctl enable ninja-proxmox.target ninja-proxmox-api.service ninja-proxmox-worker.service >/dev/null 2>&1 || true

# ---------------------------------------------------------------------------
# The ninja-proxmox CLI
# ---------------------------------------------------------------------------

say "ninja-proxmox CLI"

cat > /usr/local/bin/ninja-proxmox <<'CLIEOF'
#!/usr/bin/env bash
#
# ninja-proxmox — day-to-day control of the service on this box.
#
set -Eeuo pipefail
. /etc/ninja-proxmox.conf

die() { printf 'ninja-proxmox: %s\n' "$*" >&2; exit 1; }
need_root() { [ "$(id -u)" -eq 0 ] || die "that needs sudo"; }

# Resolve "api" | "worker" | "" (both) to unit names.
units() {
  case "${1:-}" in
    api)    printf 'ninja-proxmox-api.service' ;;
    worker) printf 'ninja-proxmox-worker.service' ;;
    ""|all) printf 'ninja-proxmox-api.service ninja-proxmox-worker.service' ;;
    *) die "unknown component '${1}' — use api, worker, or nothing for both" ;;
  esac
}

# Run an npm script as the app user with the env file loaded, so `key create`
# and `check` behave the same as they would under systemd.
as_app() {
  need_root
  set -a; . "$ENV_FILE"; set +a
  cd "$APP_DIR"
  exec sudo -u "$APP_USER" --preserve-env sh -c "cd '$APP_DIR' && $*"
}

cmd="${1:-status}"; shift || true

case "$cmd" in
  status)
    systemctl --no-pager --lines=0 status $(units "${1:-}") || true
    printf '\n--- health ---\n'
    curl -fsS --max-time 3 "http://127.0.0.1:${APP_PORT}/v1/health" \
      && printf '\n' \
      || printf 'no response on :%s (not built yet, or not running)\n' "$APP_PORT"
    printf '\n--- version ---\n'
    git -C "$APP_DIR" log -1 --format='%h %s (%cr)' 2>/dev/null || echo 'no checkout'
    ;;
  start|stop|restart)
    need_root; systemctl "$cmd" $(units "${1:-}") ;;
  logs)
    comp=""; case "${1:-}" in api|worker|all) comp="$1"; shift ;; esac
    args=(); for u in $(units "$comp"); do args+=(-u "$u"); done
    exec journalctl "${args[@]}" -n 200 "$@" ;;
  update)
    need_root
    ref="${1:-}"
    if [ -n "$ref" ]; then
      sed -i "s|^REPO_REF=.*|REPO_REF='${ref}'|" /etc/ninja-proxmox.conf
    fi
    [ -x /usr/local/lib/ninja-proxmox/runtime.sh ] \
      || die "runtime installer missing — re-run update-ninja-proxmox.sh from the Proxmox host"
    exec /usr/local/lib/ninja-proxmox/runtime.sh --deploy --migrate --restart ;;
  key)
    [ "${1:-}" = "create" ] || die "usage: ninja-proxmox key create --name <n> --scopes <a,b>"
    shift
    as_app "npm run key:create -- $*" ;;
  check)   as_app "npm run pve:check" ;;
  migrate) as_app "npm run migrate" ;;
  env)
    need_root; "${EDITOR:-nano}" "$ENV_FILE"
    printf 'Edited %s — restart to apply: sudo ninja-proxmox restart\n' "$ENV_FILE" ;;
  doctor)
    printf 'node       %s\n' "$(node -v 2>/dev/null || echo MISSING)"
    printf 'postgres   %s\n' "$(pg_isready -q && echo up || echo DOWN)"
    printf 'redis      %s\n' "$( (redis-cli ping 2>/dev/null || valkey-cli ping 2>/dev/null) || echo DOWN)"
    set -a; . "$ENV_FILE"; set +a
    printf 'pve host   %s\n' "${PVE_HOST:-unset}"
    if [ -n "${PVE_HOST:-}" ]; then
      code="$(curl -sk -o /dev/null -w '%{http_code}' --max-time 5 \
        -H "Authorization: PVEAPIToken=${PVE_TOKEN_ID}=${PVE_TOKEN_SECRET}" \
        "https://${PVE_HOST}/api2/json/version" || echo 000)"
      case "$code" in
        200) printf 'pve token  ok (200 from /version)\n' ;;
        401) printf 'pve token  REJECTED (401) — check PVE_TOKEN_ID/SECRET\n' ;;
        000) printf 'pve api    UNREACHABLE — check PVE_HOST and the firewall\n' ;;
        *)   printf 'pve api    HTTP %s\n' "$code" ;;
      esac
    fi
    printf 'checkout   %s\n' "$(git -C "$APP_DIR" log -1 --format='%h %s' 2>/dev/null || echo none)"
    printf 'built      %s\n' "$([ -f "${APP_DIR}/dist/index.js" ] && echo yes || echo 'no — dist/index.js missing')"
    ;;
  -h|--help|help)
    cat <<'USAGE'
ninja-proxmox <command>

  status [api|worker]     units, health check and current commit
  start|stop|restart [c]  control the service (sudo)
  logs [api|worker] [-f]  journal for one component or both
  update [ref]            fetch, build, migrate and restart (sudo)
  key create --name X --scopes read,operate
  check                   verify PVE reachability and token permissions
  migrate                 run database migrations
  env                     edit /etc/ninja-proxmox/env (sudo)
  doctor                  one-line status of every dependency
USAGE
    ;;
  *) die "unknown command '${cmd}' — try: ninja-proxmox help" ;;
esac
CLIEOF
chmod 755 /usr/local/bin/ninja-proxmox

# Keep a copy of this installer where the CLI's `update` can find it.
install -d -m 755 /usr/local/lib/ninja-proxmox
install -m 755 "$0" /usr/local/lib/ninja-proxmox/runtime.sh

cat > /etc/profile.d/ninja-proxmox.sh <<'EOF'
alias np='ninja-proxmox'
alias npl='ninja-proxmox logs -f'
alias nps='ninja-proxmox status'
EOF
chmod 644 /etc/profile.d/ninja-proxmox.sh

# ---------------------------------------------------------------------------
# Restart
# ---------------------------------------------------------------------------

if [ "$RESTART" = "1" ]; then
  if [ -f "${APP_DIR}/dist/index.js" ]; then
    say "Restarting"
    systemctl restart ninja-proxmox.target
    systemctl --no-pager --lines=0 status ninja-proxmox-api.service || true
  else
    warn "nothing built yet — not starting the units"
  fi
fi

printf '\nruntime installed (app: %s)\n' "$APP_STATE"
