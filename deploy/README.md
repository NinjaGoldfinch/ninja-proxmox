# deploy — running ninja-proxmox on a Proxmox host

One script turns a Proxmox VE host into an LXC container running
ninja-proxmox, with its Proxmox API token, ACLs, TLS trust and database
already set up. Modelled on
[claude-code-lxc](https://github.com/NinjaGoldfinch/claude-code-lxc), which
uses the same three-script shape.

> **ninja-proxmox has no `src/` yet** — it is still the design document in
> [`docs/`](../docs). The provisioner builds the whole box regardless: the
> container, Postgres, Redis, the PVE token and its ACLs, the cluster CA, the
> environment file and the systemd units. It then tells you the app is not
> built and leaves the units stopped. When code lands, one
> `update-ninja-proxmox.sh <CTID>` brings it up. Nothing gets redone.

## The three scripts

| Script | Runs on | Does |
| --- | --- | --- |
| `provision-ninja-proxmox-lxc.sh` | Proxmox host | Builds the container from scratch: PVE token, ACLs, CA, database, app, units |
| `update-ninja-proxmox.sh` | Proxmox host | Redeploys code onto containers that already exist. Touches no credentials |
| `ninja-proxmox-runtime.sh` | Inside the container | Installs the units and the CLI. The single source of truth both of the above push |

You run the first two. The third is shared machinery, so provisioning and
updating can never drift apart.

## Quick start

On the **Proxmox host**, as root:

```bash
git clone https://github.com/NinjaGoldfinch/ninja-proxmox
cd ninja-proxmox/deploy
./provision-ninja-proxmox-lxc.sh
```

A fixed address is worth setting for something you will bookmark and firewall:

```bash
CTID=260 CT_IP=192.168.1.60/24 CT_GW=192.168.1.1 ./provision-ninja-proxmox-lxc.sh
```

Read the scripts before you run them. They create a Proxmox user and an API
token that can administer every guest in your cluster.

## What it does that you would otherwise do by hand

- **Creates the API token and captures the secret.** Proxmox displays a token
  secret exactly once, at creation. The script catches it and writes it into
  both the container's environment file and the credentials bundle.
- **Grants the ACLs on the user *and* the token.** With `privsep=1` the
  effective permission set is the intersection of the two. Granting only one —
  the mistake nearly everyone makes once — yields a token that reads fine and
  fails at the first write.
- **Installs the cluster CA.** `/etc/pve/pve-root-ca.pem` signs every node's
  certificate, so one trust anchor covers the whole cluster and TLS
  verification stays on. The usual homelab shortcut of disabling verification
  throws away the only protection on the most privileged connection the
  service makes.
- **Writes `/etc/hosts` for every cluster node.** Node certificates are issued
  for node *names*, and the service routes to nodes by name. Without this,
  verification fails and you end up reaching for the shortcut above.
- **Sets `PVE_SELF_NODE`.** The container runs on a node it manages, so the
  service refuses power actions against its own host.
- **Leaves `Sys.PowerMgmt` ungranted.** Node reboot and shutdown are opt-in via
  `GRANT_NODE_POWER=1`.

## Configuration

Every setting is an environment variable. Defaults in parentheses.

| Variable | What it does |
| --- | --- |
| `CTID` | Container ID (next free) |
| `CT_HOSTNAME` | Hostname (`ninja-proxmox`) |
| `CORES` / `MEMORY` / `SWAP` / `DISK_GB` | Resources (`2` / `2048` MB / `1024` MB / `16` GB) |
| `ROOTFS_STORAGE` | Storage for the container disk (`local-lvm`) |
| `BRIDGE` / `CT_IP` / `CT_GW` / `CT_VLAN` | Networking (`vmbr0` / `dhcp`) |
| `NAMESERVER` | Resolvers (`1.1.1.1 9.9.9.9`) |
| `ROOTFS_URL` | linuxcontainers.org rootfs to use |
| `APP_USER` / `APP_DIR` / `APP_PORT` | Service account, checkout, listen port (`ninja` / `/opt/ninja-proxmox` / `8080`) |
| `ADMIN_USER` / `SSH_PORT` | Your login account and sshd port (`dev` / `22`) |
| `REPO_URL` / `REPO_REF` | Where the code comes from (`…/ninja-proxmox` / `main`) |
| `NODE_MAJOR` | Node.js major version (`26`) |
| `PVE_USER` / `PVE_REALM` / `PVE_TOKEN_NAME` | The token to create (`ninja` / `pve` / `ctl`) |
| `CREATE_PVE_TOKEN` | Create the user, token and ACLs (`1`). `0` to bring your own |
| `PVE_TOKEN_SECRET` | Required when the token already exists, or with `CREATE_PVE_TOKEN=0` |
| `PVE_TOKEN_ROTATE` | Delete and recreate an existing token (`0`) |
| `GRANT_NODE_POWER` | Grant `Sys.PowerMgmt` on `/nodes` (`0`) |
| `PVE_API_HOST` / `PVE_API_PORT` | What the container dials (this node's name / `8006`) |
| `PVE_TLS_MODE` | `ca` \| `verify` \| `pin` \| `insecure` (`ca`) |
| `WRITE_CLUSTER_HOSTS` | Add node entries to the container's `/etc/hosts` (`1`) |
| `FIRST_KEY_NAME` / `FIRST_KEY_SCOPES` | API key minted during provisioning (`operator` / `read,operate`) |
| `OUT_DIR_BASE` | Where the credentials bundle lands (`/root/ninja-proxmox-lxc`) |

### Bringing your own token

```bash
CREATE_PVE_TOKEN=0 \
PVE_USER=svc PVE_TOKEN_NAME=ninja \
PVE_TOKEN_SECRET=xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx \
  ./provision-ninja-proxmox-lxc.sh
```

## Updating

```bash
cd ninja-proxmox && git pull && cd deploy
./update-ninja-proxmox.sh 260                 # one container
./update-ninja-proxmox.sh 260 261             # several
./update-ninja-proxmox.sh 260 --ref v0.2.0    # pin a tag
./update-ninja-proxmox.sh 260 --no-restart
```

It refreshes the systemd units, the CLI and the application code, runs
migrations and restarts. It deliberately does **not** touch:

- `/etc/ninja-proxmox/env` — the PVE token, database password and API keys
- the Postgres cluster, beyond running migrations
- SSH keys, passwords or sudoers
- the PVE user, token or ACLs on the host

## Day to day, inside the container

```bash
ninja-proxmox status              # units, health, current commit
ninja-proxmox doctor              # one-line status of every dependency
ninja-proxmox logs -f             # follow both units
sudo ninja-proxmox restart        # or: restart api / restart worker
sudo ninja-proxmox update [ref]   # fetch, build, migrate, restart
sudo ninja-proxmox key create --name bot --scopes read,operate
ninja-proxmox check               # verify PVE token permissions
sudo ninja-proxmox env            # edit the environment file
```

`np`, `nps` and `npl` are aliases for `ninja-proxmox`, `… status` and
`… logs -f`.

## Security notes

- The credentials bundle at `/root/ninja-proxmox-lxc-<CTID>/CREDENTIALS.txt`
  holds the **Proxmox API token secret**, which the cluster will never show you
  again. File it in a password manager, then delete the directory.
- That token can administer every VM and container in the cluster. Keep this
  box on your management network and do not expose its port to the internet.
- Password authentication over SSH is off. The generated passwords are for the
  Proxmox console (`pct console <CTID>`) and for `sudo`.
- Secrets reach the guest only inside `/root/provision.env` (mode 0600), which
  is shredded when provisioning finishes. Nothing sensitive is passed on argv,
  so it never appears in `ps`.
- The container is unprivileged.
- `ninja-proxmox` runs as a `nologin` system account; the environment file is
  `0600` and owned by it.

## Teardown

```bash
pct stop <CTID> && pct destroy <CTID>
pveum user token remove ninja@pve ctl
pveum user delete ninja@pve
rm -rf /root/ninja-proxmox-lxc-<CTID>
```
