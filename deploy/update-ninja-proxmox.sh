#!/usr/bin/env bash
#
# update-ninja-proxmox.sh
#
# Refreshes ninja-proxmox on containers that already exist. Run from the
# Proxmox host, after pulling this repo.
#
#   ./update-ninja-proxmox.sh 260                 # one container
#   ./update-ninja-proxmox.sh 260 261             # several
#   ./update-ninja-proxmox.sh 260 --ref v0.2.0    # pin a tag or branch
#   ./update-ninja-proxmox.sh 260 --no-restart    # build now, restart later
#   ./update-ninja-proxmox.sh 260 --no-migrate    # skip database migrations
#
# It pushes the runtime installer, redeploys the application code, runs
# migrations and restarts the units.
#
# It deliberately does NOT touch anything you would have to redo:
#
#   * /etc/ninja-proxmox/env — the PVE token, DB password and API keys survive
#   * the Postgres cluster and its contents, beyond running migrations
#   * SSH keys, passwords, sudoers
#   * the PVE user, token or ACLs on the host
#
# Containers provisioned before /etc/ninja-proxmox.conf existed are handled:
# the runtime installer writes it on the way through.
#
set -Eeuo pipefail

C_OK=$'\033[32m'; C_WARN=$'\033[33m'; C_ERR=$'\033[31m'; C_B=$'\033[1m'; C_0=$'\033[0m'
log()  { printf '%s==>%s %s\n' "$C_B" "$C_0" "$*"; }
ok()   { printf '%s  ok%s %s\n' "$C_OK" "$C_0" "$*"; }
warn() { printf '%swarn%s %s\n' "$C_WARN" "$C_0" "$*" >&2; }
die()  { printf '%s fail%s %s\n' "$C_ERR" "$C_0" "$*" >&2; exit 1; }

RESTART=1; MIGRATE=1; REF=""
CTIDS=()
while [ $# -gt 0 ]; do
  case "$1" in
    --no-restart) RESTART=0; shift ;;
    --no-migrate) MIGRATE=0; shift ;;
    --ref)        REF="${2:-}"; [ -n "$REF" ] || die "--ref needs a value"; shift 2 ;;
    -h|--help)    sed -n '2,28p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    -*)           die "unknown option: $1" ;;
    *)            CTIDS+=("$1"); shift ;;
  esac
done

[ "$(id -u)" -eq 0 ] || die "run this as root on the Proxmox host"
command -v pct >/dev/null 2>&1 || die "pct not found — this must run on a PVE host"
[ "${#CTIDS[@]}" -gt 0 ] || die "give at least one CTID (see: pct list)"

RUNTIME_SRC="${RUNTIME_SRC:-}"
RUNTIME_URL="${RUNTIME_URL:-https://raw.githubusercontent.com/NinjaGoldfinch/ninja-proxmox/main/deploy/ninja-proxmox-runtime.sh}"
if [ -z "$RUNTIME_SRC" ]; then
  SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd || true)"
  if [ -n "$SELF_DIR" ] && [ -r "${SELF_DIR}/ninja-proxmox-runtime.sh" ]; then
    RUNTIME_SRC="${SELF_DIR}/ninja-proxmox-runtime.sh"
  else
    RUNTIME_SRC="$(mktemp)"
    curl -fL --retry 3 -o "$RUNTIME_SRC" "$RUNTIME_URL" \
      || die "could not fetch the runtime installer — clone the repo or set RUNTIME_SRC"
  fi
fi
[ -r "$RUNTIME_SRC" ] || die "RUNTIME_SRC is not readable: ${RUNTIME_SRC}"
bash -n "$RUNTIME_SRC" || die "the runtime installer is not valid bash"
ok "runtime installer: ${RUNTIME_SRC}"

FAILED=()
for CTID in "${CTIDS[@]}"; do
  log "Container ${CTID}"

  if ! pct status "$CTID" >/dev/null 2>&1; then
    warn "no such container — skipping"; FAILED+=("$CTID"); continue
  fi
  if [ "$(pct status "$CTID" | awk '{print $2}')" != "running" ]; then
    warn "container ${CTID} is not running — starting it"
    pct start "$CTID"
    for _ in $(seq 1 60); do
      pct exec "$CTID" -- test -d /run/systemd/system >/dev/null 2>&1 && break
      sleep 1
    done
  fi

  if ! pct exec "$CTID" -- test -f /etc/ninja-proxmox.conf >/dev/null 2>&1; then
    if pct exec "$CTID" -- test -x /usr/local/bin/ninja-proxmox >/dev/null 2>&1; then
      warn "no /etc/ninja-proxmox.conf — the runtime installer will write one from its defaults"
    else
      warn "container ${CTID} does not look like a ninja-proxmox box — skipping"
      FAILED+=("$CTID"); continue
    fi
  fi

  if [ -n "$REF" ]; then
    pct exec "$CTID" -- sh -c "
      if grep -q '^REPO_REF=' /etc/ninja-proxmox.conf 2>/dev/null; then
        sed -i \"s|^REPO_REF=.*|REPO_REF='${REF}'|\" /etc/ninja-proxmox.conf
      else
        echo \"REPO_REF='${REF}'\" >> /etc/ninja-proxmox.conf
      fi" || die "could not pin REPO_REF on ${CTID}"
    ok "pinned to ${REF}"
  fi

  pct push "$CTID" "$RUNTIME_SRC" /root/ninja-proxmox-runtime.sh --perms 0700

  ARGS="--deploy"
  [ "$MIGRATE" = "1" ] && ARGS="${ARGS} --migrate"
  [ "$RESTART" = "1" ] && ARGS="${ARGS} --restart"

  # shellcheck disable=SC2086
  if pct exec "$CTID" -- /root/ninja-proxmox-runtime.sh $ARGS; then
    ok "container ${CTID} updated"
  else
    warn "update failed on ${CTID} — the previous build is still in place"
    FAILED+=("$CTID")
  fi
  pct exec "$CTID" -- rm -f /root/ninja-proxmox-runtime.sh >/dev/null 2>&1 || true

  pct exec "$CTID" -- ninja-proxmox status 2>/dev/null | tail -20 || true
done

echo
if [ "${#FAILED[@]}" -gt 0 ]; then
  die "finished with problems on: ${FAILED[*]}"
fi
ok "all containers updated: ${CTIDS[*]}"
