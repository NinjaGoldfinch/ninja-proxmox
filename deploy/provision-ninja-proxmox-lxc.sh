#!/usr/bin/env bash
#
# provision-ninja-proxmox-lxc.sh
#
# Creates a Debian 13 (trixie) LXC container on a Proxmox VE host running
# ninja-proxmox — the control plane API and operator web UI for this cluster.
#
# Because it runs on the Proxmox host as root, it can do the parts that are
# otherwise a manual slog, and get them right:
#
#   * creates a privilege-separated PVE API user + token with `pveum`, and
#     captures the secret (which the API shows exactly once)
#   * grants the ACLs the token actually needs — on BOTH the user and the
#     token, because with privsep=1 the effective rights are the intersection
#     and granting only one of them silently yields a read-only token
#   * copies the cluster CA (/etc/pve/pve-root-ca.pem) into the container, so
#     TLS to every node verifies properly instead of being disabled
#   * writes /etc/hosts entries for every node in the cluster, so those
#     certificates match the names we connect to
#   * installs Node, Postgres and Redis, deploys the app and mints its first
#     API key
#   * writes a credentials bundle back to the host for your password manager
#
# RUN THIS ON THE PROXMOX HOST, AS ROOT.
#
#   chmod +x provision-ninja-proxmox-lxc.sh
#   ./provision-ninja-proxmox-lxc.sh
#
# Everything below can be overridden from the environment, e.g.
#   CTID=260 CT_IP=192.168.1.60/24 CT_GW=192.168.1.1 ./provision-ninja-proxmox-lxc.sh
#
# NOTE: ninja-proxmox is currently a design document with no src/ directory.
# This script provisions the box completely — container, database, PVE token,
# environment, systemd units — and tells you the app is not yet built. Re-run
# `update-ninja-proxmox.sh <CTID>` once code lands and it comes up.
#
set -Eeuo pipefail

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

# Container identity / resources
CTID="${CTID:-}"                                   # blank = next free ID
CT_HOSTNAME="${CT_HOSTNAME:-ninja-proxmox}"
CORES="${CORES:-2}"
MEMORY="${MEMORY:-2048}"                           # MB — api + worker + postgres
SWAP="${SWAP:-1024}"
DISK_GB="${DISK_GB:-16}"
ROOTFS_STORAGE="${ROOTFS_STORAGE:-local-lvm}"
TEMPLATE_DIR="${TEMPLATE_DIR:-/var/lib/vz/template/cache}"
CT_TAGS="${CT_TAGS:-ninja,proxmox,control-plane}"

# Networking. Set CT_IP to a CIDR (e.g. 192.168.1.60/24) plus CT_GW for static.
# A control plane is easier to firewall and to bookmark on a fixed address.
BRIDGE="${BRIDGE:-vmbr0}"
CT_IP="${CT_IP:-dhcp}"
CT_GW="${CT_GW:-}"
CT_VLAN="${CT_VLAN:-}"
NAMESERVER="${NAMESERVER:-1.1.1.1 9.9.9.9}"
TIMEZONE="${TIMEZONE:-host}"
LOCALE="${LOCALE:-en_US.UTF-8}"

ROOTFS_URL="${ROOTFS_URL:-https://images.linuxcontainers.org/images/debian/trixie/amd64/default/20260904_05:24/rootfs.tar.xz}"

# Guest layout
APP_USER="${APP_USER:-ninja}"
APP_DIR="${APP_DIR:-/opt/ninja-proxmox}"
APP_PORT="${APP_PORT:-8080}"
ENV_DIR="${ENV_DIR:-/etc/ninja-proxmox}"
SSH_PORT="${SSH_PORT:-22}"
ADMIN_USER="${ADMIN_USER:-dev}"                    # the human's login account

# Where the code comes from
REPO_URL="${REPO_URL:-https://github.com/NinjaGoldfinch/ninja-proxmox}"
REPO_REF="${REPO_REF:-main}"
NODE_MAJOR="${NODE_MAJOR:-26}"

# --- Proxmox API access -----------------------------------------------------
# The PVE user and token this box will use. Created here if absent.
PVE_REALM="${PVE_REALM:-pve}"
PVE_USER="${PVE_USER:-ninja}"
PVE_TOKEN_NAME="${PVE_TOKEN_NAME:-ctl}"
CREATE_PVE_TOKEN="${CREATE_PVE_TOKEN:-1}"
# A token's secret is displayed once, at creation. If the token already exists
# we cannot read it back: either supply it here, or set PVE_TOKEN_ROTATE=1 to
# delete and recreate it (which invalidates any other consumer of that token).
PVE_TOKEN_SECRET="${PVE_TOKEN_SECRET:-}"
PVE_TOKEN_ROTATE="${PVE_TOKEN_ROTATE:-0}"
# Node power actions (reboot/shutdown) need Sys.PowerMgmt, which no built-in
# role grants alongside VM administration. Off by default: it lets this service
# power-cycle the host it is running on. See plan §11.3.
GRANT_NODE_POWER="${GRANT_NODE_POWER:-0}"
# Which address the container dials. Defaults to this node's own name, which is
# what the cluster certificates are issued for.
PVE_API_HOST="${PVE_API_HOST:-}"
PVE_API_PORT="${PVE_API_PORT:-8006}"
# ca | pin | verify | insecure. `ca` is right for a cluster: every node's
# certificate is signed by the cluster CA, so one trust anchor covers all of
# them, where a pinned leaf fingerprint only ever covers one.
PVE_TLS_MODE="${PVE_TLS_MODE:-ca}"
WRITE_CLUSTER_HOSTS="${WRITE_CLUSTER_HOSTS:-1}"

# Optional: mint a ninja-proxmox API key for yourself during provisioning.
FIRST_KEY_NAME="${FIRST_KEY_NAME:-operator}"
FIRST_KEY_SCOPES="${FIRST_KEY_SCOPES:-read,operate}"

# The shared runtime installer. Looked for next to this script first; when that
# fails — running via `bash -c "$(curl ...)"`, say — it is fetched from
# RUNTIME_URL. Point RUNTIME_SRC at a local copy to pin it.
RUNTIME_SRC="${RUNTIME_SRC:-}"
RUNTIME_URL="${RUNTIME_URL:-https://raw.githubusercontent.com/NinjaGoldfinch/ninja-proxmox/main/deploy/ninja-proxmox-runtime.sh}"

OUT_DIR_BASE="${OUT_DIR_BASE:-/root/ninja-proxmox-lxc}"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

C_OK=$'\033[32m'; C_WARN=$'\033[33m'; C_ERR=$'\033[31m'; C_B=$'\033[1m'; C_0=$'\033[0m'
log()  { printf '%s==>%s %s\n' "$C_B" "$C_0" "$*"; }
ok()   { printf '%s  ok%s %s\n' "$C_OK" "$C_0" "$*"; }
warn() { printf '%swarn%s %s\n' "$C_WARN" "$C_0" "$*" >&2; }
die()  { printf '%s fail%s %s\n' "$C_ERR" "$C_0" "$*" >&2; exit 1; }

trap 'die "aborted at line $LINENO"' ERR

rand_str() {
  local n="${1:-32}" s=""
  while [ "${#s}" -lt "$n" ]; do
    local chunk
    chunk="$(openssl rand -base64 $((n * 2)))"
    chunk="${chunk//[^A-Za-z0-9]/}"
    s="${s}${chunk}"
  done
  printf '%s' "${s:0:n}"
}

need() { command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"; }

# ---------------------------------------------------------------------------
# Preflight
# ---------------------------------------------------------------------------

log "Preflight checks"
[ "$(id -u)" -eq 0 ] || die "run this as root on the Proxmox host"
need pct; need pvesm; need pvesh; need pveum; need openssl; need curl; need ssh-keygen; need perl
command -v pveversion >/dev/null 2>&1 || die "pveversion not found — this must run on a PVE host"

THIS_NODE="$(hostname -s)"
ok "Proxmox node: ${THIS_NODE} ($(pveversion | head -1))"

case "$PVE_TLS_MODE" in
  ca|pin|verify|insecure) ;;
  *) die "PVE_TLS_MODE must be one of: ca, pin, verify, insecure" ;;
esac
[ "$PVE_TLS_MODE" = "insecure" ] && warn "PVE_TLS_MODE=insecure disables TLS verification on the most privileged connection this box makes"

if [ -z "$CTID" ]; then
  CTID="$(pvesh get /cluster/nextid)"
  ok "allocated container ID ${CTID}"
fi
pct status "$CTID" >/dev/null 2>&1 && die "container ${CTID} already exists — pick another CTID or destroy it first"

pvesm status --storage "$ROOTFS_STORAGE" >/dev/null 2>&1 \
  || die "storage '${ROOTFS_STORAGE}' not found (pvesm status to list)"

if [ -z "$RUNTIME_SRC" ]; then
  SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd || true)"
  if [ -n "$SELF_DIR" ] && [ -r "${SELF_DIR}/ninja-proxmox-runtime.sh" ]; then
    RUNTIME_SRC="${SELF_DIR}/ninja-proxmox-runtime.sh"
    ok "runtime installer: ${RUNTIME_SRC}"
  else
    RUNTIME_SRC="$(mktemp)"
    curl -fL --retry 3 -o "$RUNTIME_SRC" "$RUNTIME_URL" \
      || die "could not fetch the runtime installer from ${RUNTIME_URL} — clone the repo or set RUNTIME_SRC"
    ok "runtime installer: fetched from ${RUNTIME_URL}"
  fi
else
  [ -r "$RUNTIME_SRC" ] || die "RUNTIME_SRC is not readable: ${RUNTIME_SRC}"
fi
bash -n "$RUNTIME_SRC" || die "the runtime installer at ${RUNTIME_SRC} is not valid bash"

mkdir -p "$TEMPLATE_DIR"
OUT_DIR="${OUT_DIR_BASE}-${CTID}"
mkdir -p "$OUT_DIR"; chmod 700 "$OUT_DIR"
ok "credentials will be written to ${OUT_DIR}"

# ---------------------------------------------------------------------------
# Learn the cluster: nodes, addresses, CA
# ---------------------------------------------------------------------------

log "Inspecting the cluster"

# /cluster/status lists every node with its ring address, which is what we want
# in the container's /etc/hosts so certificate names resolve.
CLUSTER_HOSTS=""
NODE_COUNT=0
if CS="$(pvesh get /cluster/status --output-format json 2>/dev/null)"; then
  while IFS=$'\t' read -r nname nip; do
    [ -n "$nname" ] && [ -n "$nip" ] || continue
    CLUSTER_HOSTS="${CLUSTER_HOSTS}${nip} ${nname}"$'\n'
    NODE_COUNT=$((NODE_COUNT + 1))
  # perl + JSON::PP rather than python3 or jq: a PVE host is a Perl stack and
  # JSON::PP has been core since 5.14, so this is the one parser guaranteed to
  # be there.
  done < <(printf '%s' "$CS" | perl -MJSON::PP -e '
    my $d = decode_json(do { local $/; <STDIN> });
    for my $e (@$d) {
      next unless ($e->{type} // "") eq "node";
      my $ip = $e->{ip} // ""; my $n = $e->{name} // "";
      print "$n\t$ip\n" if $ip ne "" && $n ne "";
    }' 2>/dev/null || true)
fi
if [ "$NODE_COUNT" -gt 0 ]; then
  ok "${NODE_COUNT} node(s) discovered"
else
  warn "could not enumerate cluster nodes — the container will rely on DNS"
fi

# Default the API host to this node's own name: the certificate is issued for
# it, and /etc/hosts (above) makes it resolve inside the container.
if [ -z "$PVE_API_HOST" ]; then
  PVE_API_HOST="$THIS_NODE"
  ok "PVE API host: ${PVE_API_HOST}:${PVE_API_PORT}"
fi

CA_FILE=/etc/pve/pve-root-ca.pem
CA_STAGED=""
if [ "$PVE_TLS_MODE" = "ca" ]; then
  [ -r "$CA_FILE" ] || die "PVE_TLS_MODE=ca but ${CA_FILE} is unreadable"
  CA_STAGED="$CA_FILE"
  ok "cluster CA found — every node's certificate will verify against it"
fi

PVE_TLS_FINGERPRINT=""
if [ "$PVE_TLS_MODE" = "pin" ]; then
  LEAF=/etc/pve/local/pveproxy-ssl.pem
  [ -r "$LEAF" ] || LEAF=/etc/pve/local/pve-ssl.pem
  [ -r "$LEAF" ] || die "could not read a pveproxy certificate to pin"
  PVE_TLS_FINGERPRINT="$(openssl x509 -in "$LEAF" -noout -fingerprint -sha256 | sed 's/.*=//')"
  ok "pinned fingerprint: ${PVE_TLS_FINGERPRINT}"
  [ "$NODE_COUNT" -gt 1 ] && warn "this cluster has ${NODE_COUNT} nodes and a pinned leaf covers only ${THIS_NODE} — PVE_TLS_MODE=ca is the right choice here"
fi

# ---------------------------------------------------------------------------
# Proxmox API user, token and ACLs
# ---------------------------------------------------------------------------

PVE_USER_FULL="${PVE_USER}@${PVE_REALM}"
PVE_TOKEN_ID="${PVE_USER_FULL}!${PVE_TOKEN_NAME}"

if [ "$CREATE_PVE_TOKEN" = "1" ]; then
  log "Proxmox API credentials"

  if pveum user list --output-format json 2>/dev/null | grep -q "\"${PVE_USER_FULL}\""; then
    ok "user ${PVE_USER_FULL} already exists"
  else
    [ "$PVE_REALM" = "pve" ] || die "realm '${PVE_REALM}' is not the built-in pve realm — create ${PVE_USER_FULL} yourself and re-run with CREATE_PVE_TOKEN=0"
    pveum user add "$PVE_USER_FULL" --comment "ninja-proxmox control plane (CT ${CTID})"
    ok "created user ${PVE_USER_FULL}"
  fi

  TOKEN_EXISTS=0
  pvesh get "/access/users/${PVE_USER_FULL}/token/${PVE_TOKEN_NAME}" >/dev/null 2>&1 && TOKEN_EXISTS=1

  if [ "$TOKEN_EXISTS" = "1" ] && [ "$PVE_TOKEN_ROTATE" = "1" ]; then
    warn "rotating existing token ${PVE_TOKEN_ID} — anything else using it will break"
    pveum user token remove "$PVE_USER_FULL" "$PVE_TOKEN_NAME" >/dev/null
    TOKEN_EXISTS=0
  fi

  if [ "$TOKEN_EXISTS" = "1" ]; then
    [ -n "$PVE_TOKEN_SECRET" ] || die \
"token ${PVE_TOKEN_ID} already exists and its secret cannot be read back.
       Either pass PVE_TOKEN_SECRET=<uuid>, or set PVE_TOKEN_ROTATE=1 to replace it."
    ok "using the supplied secret for existing token ${PVE_TOKEN_ID}"
  else
    TOKEN_JSON="$(pvesh create "/access/users/${PVE_USER_FULL}/token/${PVE_TOKEN_NAME}" \
      --privsep 1 --comment "ninja-proxmox CT ${CTID}" --output-format json)"
    PVE_TOKEN_SECRET="$(printf '%s' "$TOKEN_JSON" | perl -MJSON::PP -e \
      'my $d = decode_json(do { local $/; <STDIN> }); print $d->{value} // "";')"
    [ -n "$PVE_TOKEN_SECRET" ] || die "could not read the token secret out of: ${TOKEN_JSON}"
    ok "created privilege-separated token ${PVE_TOKEN_ID}"
  fi

  # With privsep=1 the effective permission set is the INTERSECTION of the
  # user's and the token's. Granting only the token yields a token that can do
  # nothing; granting only the user yields the same. Both, every time.
  log "Granting ACLs"
  for subject in "--user ${PVE_USER_FULL}" "--token ${PVE_TOKEN_ID}"; do
    # shellcheck disable=SC2086
    pveum acl modify /         $subject --role PVEAuditor       >/dev/null
    # shellcheck disable=SC2086
    pveum acl modify /vms      $subject --role PVEVMAdmin       >/dev/null
    # shellcheck disable=SC2086
    pveum acl modify /storage  $subject --role PVEDatastoreUser >/dev/null
  done
  ok "PVEAuditor on /, PVEVMAdmin on /vms, PVEDatastoreUser on /storage"

  if [ "$GRANT_NODE_POWER" = "1" ]; then
    pveum role add NinjaNodePower --privs "Sys.PowerMgmt,Sys.Audit" >/dev/null 2>&1 || true
    pveum acl modify /nodes --user  "$PVE_USER_FULL" --role NinjaNodePower >/dev/null
    pveum acl modify /nodes --token "$PVE_TOKEN_ID"  --role NinjaNodePower >/dev/null
    warn "granted Sys.PowerMgmt on /nodes — this token can now reboot the host it runs on"
  else
    ok "node power actions NOT granted (GRANT_NODE_POWER=1 to enable)"
  fi

  # Prove it works before we build a container around it.
  CHECK="$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 \
    --cacert "$CA_FILE" --resolve "${THIS_NODE}:${PVE_API_PORT}:127.0.0.1" \
    -H "Authorization: PVEAPIToken=${PVE_TOKEN_ID}=${PVE_TOKEN_SECRET}" \
    "https://${THIS_NODE}:${PVE_API_PORT}/api2/json/version" 2>/dev/null || echo 000)"
  case "$CHECK" in
    200) ok "token verified against the live API" ;;
    401) die "the API rejected the token we just created (401) — check the realm and ACLs" ;;
    *)   warn "could not verify the token locally (HTTP ${CHECK}); the container will retry" ;;
  esac
else
  log "Proxmox API credentials"
  [ -n "$PVE_TOKEN_SECRET" ] || die "CREATE_PVE_TOKEN=0 requires PVE_TOKEN_SECRET"
  ok "using the supplied token ${PVE_TOKEN_ID}"
fi

# ---------------------------------------------------------------------------
# Fetch and verify the rootfs image
# ---------------------------------------------------------------------------

log "Fetching rootfs image"
IMG_STAMP="$(printf '%s' "$ROOTFS_URL" | awk -F/ '{print $(NF-1)}' | tr -cd 'A-Za-z0-9_')"
TEMPLATE_FILE="${TEMPLATE_DIR}/debian-trixie-${IMG_STAMP}-rootfs.tar.xz"

if [ -s "$TEMPLATE_FILE" ]; then
  ok "template already present: ${TEMPLATE_FILE}"
else
  curl -fL --retry 3 --progress-bar -o "${TEMPLATE_FILE}.part" "$ROOTFS_URL" \
    || die "could not download ${ROOTFS_URL}"
  mv "${TEMPLATE_FILE}.part" "$TEMPLATE_FILE"
  ok "downloaded $(du -h "$TEMPLATE_FILE" | cut -f1)"
fi

SUMS_URL="${ROOTFS_URL%/*}/SHA256SUMS"
if SUMS="$(curl -fsSL --retry 2 "$SUMS_URL" 2>/dev/null)"; then
  EXPECT="$(printf '%s\n' "$SUMS" | awk '$2 ~ /rootfs\.tar\.xz$/ {print $1; exit}')"
  if [ -n "$EXPECT" ]; then
    ACTUAL="$(sha256sum "$TEMPLATE_FILE" | awk '{print $1}')"
    [ "$EXPECT" = "$ACTUAL" ] || die "SHA256 mismatch for rootfs (expected ${EXPECT}, got ${ACTUAL})"
    ok "SHA256 verified"
  else
    warn "SHA256SUMS fetched but no rootfs.tar.xz entry — skipping verification"
  fi
else
  warn "could not fetch ${SUMS_URL} — skipping checksum verification"
fi

# ---------------------------------------------------------------------------
# Generate credentials
# ---------------------------------------------------------------------------

log "Generating credentials"
ROOT_PW="$(rand_str 32)"
ADMIN_PW="$(rand_str 32)"
DB_PW="$(rand_str 32)"

LOGIN_KEY="${OUT_DIR}/id_ed25519_${CT_HOSTNAME}"
if [ ! -f "$LOGIN_KEY" ]; then
  ssh-keygen -t ed25519 -a 100 -N '' -C "${ADMIN_USER}@${CT_HOSTNAME} (login)" -f "$LOGIN_KEY" >/dev/null
fi
chmod 600 "$LOGIN_KEY"
ok "login keypair ready"

# ---------------------------------------------------------------------------
# Create the container
# ---------------------------------------------------------------------------

log "Creating LXC ${CTID} (${CT_HOSTNAME})"
NET0="name=eth0,bridge=${BRIDGE},firewall=1"
if [ "$CT_IP" = "dhcp" ]; then
  NET0="${NET0},ip=dhcp,ip6=auto"
else
  NET0="${NET0},ip=${CT_IP}"
  [ -n "$CT_GW" ] && NET0="${NET0},gw=${CT_GW}"
fi
[ -n "$CT_VLAN" ] && NET0="${NET0},tag=${CT_VLAN}"

pct create "$CTID" "$TEMPLATE_FILE" \
  --hostname "$CT_HOSTNAME" \
  --ostype debian \
  --arch amd64 \
  --cores "$CORES" \
  --memory "$MEMORY" \
  --swap "$SWAP" \
  --rootfs "${ROOTFS_STORAGE}:${DISK_GB}" \
  --unprivileged 1 \
  --features nesting=1 \
  --net0 "$NET0" \
  --nameserver "$NAMESERVER" \
  --onboot 1 \
  --start 0 \
  --tags "$CT_TAGS" \
  --ssh-public-keys "${LOGIN_KEY}.pub" \
  --description "ninja-proxmox control plane. Provisioned $(date -Is)."

pct set "$CTID" --timezone "$TIMEZONE" >/dev/null 2>&1 || warn "could not set timezone"
ok "container created"

log "Starting container"
pct start "$CTID"

for _ in $(seq 1 60); do
  pct exec "$CTID" -- test -d /run/systemd/system >/dev/null 2>&1 && break
  sleep 1
done
pct exec "$CTID" -- test -d /run/systemd/system >/dev/null 2>&1 \
  || die "container did not reach systemd — check 'pct console ${CTID}'"

NET_OK=0
for _ in $(seq 1 45); do
  if pct exec "$CTID" -- getent hosts deb.debian.org >/dev/null 2>&1; then NET_OK=1; break; fi
  sleep 2
done
[ "$NET_OK" -eq 1 ] || die "no network/DNS inside the container — check bridge ${BRIDGE} and NAMESERVER"
ok "container is up with working DNS"

# ---------------------------------------------------------------------------
# Push provisioning inputs (never via argv, so secrets stay out of ps output)
# ---------------------------------------------------------------------------

log "Provisioning the guest"

STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"; die "aborted at line $LINENO"' ERR

cat >"${STAGE}/provision.env" <<ENVEOF
APP_USER='${APP_USER}'
APP_DIR='${APP_DIR}'
APP_PORT='${APP_PORT}'
ENV_DIR='${ENV_DIR}'
ADMIN_USER='${ADMIN_USER}'
SSH_PORT='${SSH_PORT}'
LOCALE='${LOCALE}'
CT_HOSTNAME='${CT_HOSTNAME}'
NODE_MAJOR='${NODE_MAJOR}'
REPO_URL='${REPO_URL}'
REPO_REF='${REPO_REF}'
ROOT_PW='${ROOT_PW}'
ADMIN_PW='${ADMIN_PW}'
DB_PW='${DB_PW}'
PVE_API_HOST='${PVE_API_HOST}'
PVE_API_PORT='${PVE_API_PORT}'
PVE_TOKEN_ID='${PVE_TOKEN_ID}'
PVE_TOKEN_SECRET='${PVE_TOKEN_SECRET}'
PVE_TLS_MODE='${PVE_TLS_MODE}'
PVE_TLS_FINGERPRINT='${PVE_TLS_FINGERPRINT}'
PVE_SELF_NODE='${THIS_NODE}'
WRITE_CLUSTER_HOSTS='${WRITE_CLUSTER_HOSTS}'
FIRST_KEY_NAME='${FIRST_KEY_NAME}'
FIRST_KEY_SCOPES='${FIRST_KEY_SCOPES}'
ENVEOF

printf '%s' "$CLUSTER_HOSTS" > "${STAGE}/cluster-hosts"
[ -n "$CA_STAGED" ] && cp "$CA_STAGED" "${STAGE}/pve-root-ca.pem"
cp "${LOGIN_KEY}.pub" "${STAGE}/login_key.pub"

# --- guest script -----------------------------------------------------------
cat >"${STAGE}/provision.sh" <<'GUESTEOF'
#!/usr/bin/env bash
set -Eeuo pipefail
. /root/provision.env
export DEBIAN_FRONTEND=noninteractive

say() { printf '\n--- %s\n' "$*"; }

say "Base packages"
apt-get update -qq
apt-get install -y -qq --no-install-recommends \
  ca-certificates curl wget gnupg git openssh-server sudo jq less nano \
  procps psmisc file xz-utils unzip locales tzdata bash-completion \
  iproute2 iputils-ping dnsutils build-essential python3

say "Locale"
sed -i "s/^# *${LOCALE}/${LOCALE}/" /etc/locale.gen || true
grep -q "^${LOCALE}" /etc/locale.gen || echo "${LOCALE} UTF-8" >> /etc/locale.gen
locale-gen >/dev/null
update-locale LANG="${LOCALE}" LC_ALL="${LOCALE}"

say "Users"
printf 'root:%s\n' "$ROOT_PW" | chpasswd
if ! id -u "$ADMIN_USER" >/dev/null 2>&1; then
  adduser --disabled-password --gecos "" --shell /bin/bash "$ADMIN_USER"
fi
printf '%s:%s\n' "$ADMIN_USER" "$ADMIN_PW" | chpasswd
usermod -aG sudo "$ADMIN_USER"
echo "Defaults:${ADMIN_USER} timestamp_timeout=30" > "/etc/sudoers.d/90-${ADMIN_USER}"
chmod 440 "/etc/sudoers.d/90-${ADMIN_USER}"

# The service account owns the code and runs the units. No login, no password:
# nothing should ever be `su - ninja`.
if ! id -u "$APP_USER" >/dev/null 2>&1; then
  adduser --system --group --disabled-password --shell /usr/sbin/nologin \
    --home "$APP_DIR" --no-create-home "$APP_USER"
fi

ADMIN_HOME="$(getent passwd "$ADMIN_USER" | cut -d: -f6)"

say "SSH"
install -d -m 700 -o "$ADMIN_USER" -g "$ADMIN_USER" "${ADMIN_HOME}/.ssh"
install -m 600 -o "$ADMIN_USER" -g "$ADMIN_USER" /root/login_key.pub "${ADMIN_HOME}/.ssh/authorized_keys"
cat > /etc/ssh/sshd_config.d/99-ninja-proxmox.conf <<EOF
Port ${SSH_PORT}
PermitRootLogin prohibit-password
PasswordAuthentication no
KbdInteractiveAuthentication no
PubkeyAuthentication yes
AuthenticationMethods publickey
X11Forwarding no
ClientAliveInterval 60
ClientAliveCountMax 3
AllowUsers ${ADMIN_USER} root
EOF
# Debian 13 defaults to socket activation, which ignores the Port directive.
systemctl disable --now ssh.socket >/dev/null 2>&1 || true
systemctl enable ssh.service >/dev/null 2>&1 || true
sshd -t
systemctl restart ssh.service

say "Cluster host entries"
if [ "$WRITE_CLUSTER_HOSTS" = "1" ] && [ -s /root/cluster-hosts ]; then
  # PVE certificates are issued for node names. Resolving them here is what
  # lets TLS verification succeed instead of being switched off.
  sed -i '/# ninja-proxmox cluster nodes/,/# end ninja-proxmox/d' /etc/hosts
  {
    echo "# ninja-proxmox cluster nodes"
    cat /root/cluster-hosts
    echo "# end ninja-proxmox"
  } >> /etc/hosts
  echo "added $(wc -l < /root/cluster-hosts) node entries"
else
  echo "skipped"
fi

say "Proxmox cluster CA"
install -d -m 755 "$ENV_DIR"
if [ -f /root/pve-root-ca.pem ]; then
  install -m 644 /root/pve-root-ca.pem "${ENV_DIR}/pve-root-ca.pem"
  # Also add it to the system store so curl and psql-adjacent tooling agree.
  install -m 644 /root/pve-root-ca.pem /usr/local/share/ca-certificates/pve-root-ca.crt
  update-ca-certificates >/dev/null 2>&1 || true
  echo "installed"
else
  echo "not supplied (TLS mode is ${PVE_TLS_MODE})"
fi

say "Node.js ${NODE_MAJOR}"
install -d -m 0755 /etc/apt/keyrings
if curl -fsSL https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key \
     | gpg --dearmor -o /etc/apt/keyrings/nodesource.gpg 2>/dev/null; then
  chmod 644 /etc/apt/keyrings/nodesource.gpg
  echo "deb [signed-by=/etc/apt/keyrings/nodesource.gpg] https://deb.nodesource.com/node_${NODE_MAJOR}.x nodistro main" \
    > /etc/apt/sources.list.d/nodesource.list
  apt-get update -qq && apt-get install -y -qq nodejs || {
    echo "NodeSource has no node_${NODE_MAJOR}.x — falling back to Debian's nodejs"
    rm -f /etc/apt/sources.list.d/nodesource.list
    apt-get update -qq && apt-get install -y -qq nodejs npm || true
  }
else
  apt-get install -y -qq nodejs npm || true
fi
node -v || echo "WARNING: node did not install"

say "Postgres"
apt-get install -y -qq postgresql postgresql-client
systemctl enable --now postgresql
for _ in $(seq 1 30); do pg_isready -q && break; sleep 1; done
sudo -u postgres psql -tAc "SELECT 1 FROM pg_roles WHERE rolname='ninja'" | grep -q 1 \
  || sudo -u postgres psql -qc "CREATE ROLE ninja LOGIN PASSWORD '${DB_PW}'"
sudo -u postgres psql -tAc "SELECT 1 FROM pg_database WHERE datname='ninjaproxmox'" | grep -q 1 \
  || sudo -u postgres createdb -O ninja ninjaproxmox
echo "database ninjaproxmox owned by ninja"

say "Redis"
# Debian 13 ships both redis and valkey; either satisfies the client library.
if apt-get install -y -qq redis-server 2>/dev/null; then
  systemctl enable --now redis-server
  REDIS_UNIT=redis-server
elif apt-get install -y -qq valkey-server 2>/dev/null; then
  systemctl enable --now valkey-server
  REDIS_UNIT=valkey-server
else
  echo "WARNING: neither redis-server nor valkey-server could be installed"
  REDIS_UNIT=""
fi
[ -n "$REDIS_UNIT" ] && echo "using ${REDIS_UNIT}"

say "Environment file"
# 0600, owned by the service account. This holds the token that can destroy
# every guest in the cluster; it is the most sensitive file on the box.
umask 077
cat > "${ENV_DIR}/env" <<EOF
# Written by provision-ninja-proxmox-lxc.sh. Edit with: sudo ninja-proxmox env
NODE_ENV=production
PORT=${APP_PORT}
HOST=0.0.0.0
LOG_LEVEL=info

DATABASE_URL=postgres://ninja:${DB_PW}@127.0.0.1:5432/ninjaproxmox
REDIS_URL=redis://127.0.0.1:6379

PVE_HOST=${PVE_API_HOST}:${PVE_API_PORT}
PVE_TOKEN_ID=${PVE_TOKEN_ID}
PVE_TOKEN_SECRET=${PVE_TOKEN_SECRET}
PVE_TLS_MODE=${PVE_TLS_MODE}
PVE_TLS_FINGERPRINT=${PVE_TLS_FINGERPRINT}
PVE_CA_FILE=${ENV_DIR}/pve-root-ca.pem
# The node this container runs on. Node power actions targeting it would take
# this service down with the host, so it refuses them without an explicit
# override. See plan section 11.3.
PVE_SELF_NODE=${PVE_SELF_NODE}

AUTH_DISABLED=false
EOF
chown "${APP_USER}:${APP_USER}" "${ENV_DIR}/env"
chmod 600 "${ENV_DIR}/env"
umask 022
echo "wrote ${ENV_DIR}/env"

say "ninja-proxmox runtime"
# ninja-proxmox-runtime.sh is the single source of truth for the units and the
# CLI; provisioning and updating both go through it so they cannot drift.
APP_USER="$APP_USER" APP_DIR="$APP_DIR" APP_PORT="$APP_PORT" \
ENV_DIR="$ENV_DIR" ENV_FILE="${ENV_DIR}/env" \
REPO_URL="$REPO_URL" REPO_REF="$REPO_REF" \
  /root/ninja-proxmox-runtime.sh --deploy --migrate --restart

say "First API key"
if [ -f "${APP_DIR}/dist/index.js" ]; then
  set -a; . "${ENV_DIR}/env"; set +a
  sudo -u "$APP_USER" --preserve-env sh -c \
    "cd '${APP_DIR}' && npm run key:create -- --name '${FIRST_KEY_NAME}' --scopes '${FIRST_KEY_SCOPES}'" \
    > /root/first-key.txt 2>&1 || echo "key minting failed — see /root/first-key.txt"
else
  echo "skipped — nothing built yet" > /root/first-key.txt
fi

say "Cleanup"
shred -u /root/provision.env 2>/dev/null || rm -f /root/provision.env
rm -f /root/login_key.pub /root/ninja-proxmox-runtime.sh /root/cluster-hosts /root/pve-root-ca.pem
GUESTEOF

pct push "$CTID" "${STAGE}/provision.env" /root/provision.env --perms 0600
pct push "$CTID" "${STAGE}/provision.sh"  /root/provision.sh  --perms 0700
pct push "$CTID" "${STAGE}/login_key.pub" /root/login_key.pub --perms 0644
pct push "$CTID" "${STAGE}/cluster-hosts" /root/cluster-hosts --perms 0644
[ -f "${STAGE}/pve-root-ca.pem" ] && pct push "$CTID" "${STAGE}/pve-root-ca.pem" /root/pve-root-ca.pem --perms 0644
pct push "$CTID" "$RUNTIME_SRC" /root/ninja-proxmox-runtime.sh --perms 0700

pct exec "$CTID" -- /root/provision.sh
rm -rf "$STAGE"
trap 'die "aborted at line $LINENO"' ERR
ok "guest provisioned"

# ---------------------------------------------------------------------------
# Collect results
# ---------------------------------------------------------------------------

CT_ADDR="$(pct exec "$CTID" -- sh -c "ip -4 -o addr show dev eth0 | awk '{print \$4}' | cut -d/ -f1" 2>/dev/null | head -1)"
[ -n "$CT_ADDR" ] || CT_ADDR="<container-ip>"

APP_BUILT=0
pct exec "$CTID" -- test -f "${APP_DIR}/dist/index.js" >/dev/null 2>&1 && APP_BUILT=1

FIRST_KEY="$(pct exec "$CTID" -- cat /root/first-key.txt 2>/dev/null || echo 'not minted')"
HOSTKEY_FPS="$(pct exec "$CTID" -- sh -c 'for f in /etc/ssh/ssh_host_*_key.pub; do ssh-keygen -lf "$f"; done' 2>/dev/null || echo 'unavailable')"

# ---------------------------------------------------------------------------
# Credentials bundle
# ---------------------------------------------------------------------------

CRED_FILE="${OUT_DIR}/CREDENTIALS.txt"
cat > "$CRED_FILE" <<EOF
================================================================================
ninja-proxmox — container ${CTID} (${CT_HOSTNAME})
Provisioned $(date -Is) on Proxmox node ${THIS_NODE}
================================================================================

-- Password manager: Server item — ${CT_HOSTNAME} -------------------------------
Address:         ${CT_ADDR}
Web UI:          http://${CT_ADDR}:${APP_PORT}/
Username:        ${ADMIN_USER}
Password:        ${ADMIN_PW}
Root password:   ${ROOT_PW}
Notes:           Password auth over SSH is DISABLED. These are for the Proxmox
                 console (pct console ${CTID} / pct enter ${CTID}) and for sudo.

-- Password manager: SSH Key item — box login -----------------------------------
Private key file: ${LOGIN_KEY}
Public key:       $(cat "${LOGIN_KEY}.pub")

Connect with:
  ssh -i ${LOGIN_KEY} -p ${SSH_PORT} ${ADMIN_USER}@${CT_ADDR}

Container SSH host key fingerprints (verify on first connect):
${HOSTKEY_FPS}

-- Password manager: Proxmox API token ------------------------------------------
Token ID:        ${PVE_TOKEN_ID}
Secret:          ${PVE_TOKEN_SECRET}
Privilege sep:   yes (privsep=1)
Granted:         PVEAuditor on /, PVEVMAdmin on /vms, PVEDatastoreUser on /storage
Node power:      $([ "$GRANT_NODE_POWER" = "1" ] && echo "GRANTED (Sys.PowerMgmt on /nodes)" || echo "not granted")
Lives in:        ${ENV_DIR}/env inside CT ${CTID} (mode 0600, owner ${APP_USER})

Proxmox shows a token secret exactly once, at creation. This file is the only
other copy. Revoke with:
  pveum user token remove ${PVE_USER_FULL} ${PVE_TOKEN_NAME}

-- Database ----------------------------------------------------------------------
DATABASE_URL:    postgres://ninja:${DB_PW}@127.0.0.1:5432/ninjaproxmox
                 (loopback only, inside the container)

-- ninja-proxmox API key ---------------------------------------------------------
${FIRST_KEY}

-- TLS to Proxmox ----------------------------------------------------------------
Mode:            ${PVE_TLS_MODE}
API host:        ${PVE_API_HOST}:${PVE_API_PORT}
$([ "$PVE_TLS_MODE" = "ca" ] && echo "CA:              ${ENV_DIR}/pve-root-ca.pem (cluster root, covers every node)")
$([ "$PVE_TLS_MODE" = "pin" ] && echo "Fingerprint:     ${PVE_TLS_FINGERPRINT}")
Cluster nodes resolved via /etc/hosts inside the container, so certificate
names match what we dial.

-- Day to day (inside the container) ---------------------------------------------
ninja-proxmox status              units, health, current commit
ninja-proxmox doctor              one-line status of every dependency
ninja-proxmox logs -f             follow both units
sudo ninja-proxmox restart        restart api + worker
sudo ninja-proxmox update [ref]   fetch, build, migrate, restart
sudo ninja-proxmox key create --name bot --scopes read,operate
ninja-proxmox check               verify PVE token permissions
sudo ninja-proxmox env            edit the environment file

Aliases: np, nps (status), npl (logs -f)
================================================================================
EOF
chmod 600 "$CRED_FILE"

# ---------------------------------------------------------------------------
# Done
# ---------------------------------------------------------------------------

if [ "$APP_BUILT" = "1" ]; then
  STATE_MSG="${C_OK}${C_B}ninja-proxmox is running.${C_0}

  Web UI:  http://${CT_ADDR}:${APP_PORT}/
  Health:  curl http://${CT_ADDR}:${APP_PORT}/v1/health
  Docs:    http://${CT_ADDR}:${APP_PORT}/docs

Your first API key is in the credentials bundle."
else
  STATE_MSG="${C_WARN}${C_B}The box is ready; the application is not built yet.${C_0}

ninja-proxmox is still a design document — the repository has docs/ but no
src/. Everything else is done and verified: the container, Postgres, Redis,
the PVE token and its ACLs, the cluster CA, the environment file and the
systemd units. Nothing here needs redoing.

When the code lands, pick it up from the Proxmox host with:

  ./update-ninja-proxmox.sh ${CTID}

or from inside the container:

  sudo ninja-proxmox update"
fi

cat <<EOF

${C_OK}${C_B}Container ${CTID} (${CT_HOSTNAME}) is up at ${CT_ADDR}.${C_0}

Credentials bundle: ${C_B}${CRED_FILE}${C_0}
  Contains the Proxmox API token secret, which the cluster will never show you
  again. File it in your password manager, then delete ${OUT_DIR}.

${STATE_MSG}

${C_B}Get in:${C_0}
  ssh -i ${LOGIN_KEY} -p ${SSH_PORT} ${ADMIN_USER}@${CT_ADDR}
  ninja-proxmox doctor

${C_B}Worth knowing:${C_0}
  * This container runs on ${THIS_NODE}, a node it manages. PVE_SELF_NODE is set
    so the service refuses power actions against its own host.
  * The token can administer every VM and container in the cluster. Keep this
    box on your management network; do not expose ${APP_PORT} to the internet.
  * Node power actions are $([ "$GRANT_NODE_POWER" = "1" ] && echo "GRANTED" || echo "not granted") — re-run with GRANT_NODE_POWER=1 to change that.

${C_B}Teardown:${C_0}
  pct stop ${CTID} && pct destroy ${CTID}
  pveum user token remove ${PVE_USER_FULL} ${PVE_TOKEN_NAME}
  pveum user delete ${PVE_USER_FULL}
  rm -rf ${OUT_DIR}

EOF
