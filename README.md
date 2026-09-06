# ninja-proxmox

A self-hosted control plane for a Proxmox VE cluster: a safe HTTP API and an
operator web UI over the Proxmox API. Downstream — the UI, a CLI, automation,
bots — talks to ninja-proxmox. Only ninja-proxmox talks to `pveproxy`.

> **Status: planning.** Nothing is implemented yet. The design lives in
> [docs/ninja-proxmox-plan.md](docs/ninja-proxmox-plan.md); the upstream calls
> it depends on are catalogued in
> [docs/proxmox-api-surface.md](docs/proxmox-api-surface.md). Read the plan
> before writing code — several decisions there are forced by Proxmox
> behaviour that is not obvious until it bites.

**Not affiliated with Proxmox Server Solutions GmbH.**

---

## Why

|  |  |
| --- | --- |
| **Hide the PVE credential** | The API token exists in one place: this service's environment. No browser or downstream project holds it. |
| **Make mutations legible** | Every Proxmox mutation returns a worker id, not a result — a `200` means "a worker was forked", not "it worked". We turn that into a real task with status, history and an owner. |
| **Protect the cluster** | `pvedaemon` has three workers by default. A client that fans out starves the Proxmox UI itself. One governed client, one concurrency budget. |
| **Narrow the blast radius** | Scopes, per-resource policy, confirmation tokens, protected guests, and an audit log in front of an API that will otherwise delete a VM on request. |
| **One stable contract** | Guest, task and error shapes stay put across Proxmox upgrades. |

## What it covers

Guest lifecycle for QEMU and LXC, snapshots, backup and restore, migration,
cloning, allow-listed config edits, storage, node and cluster health, task
history, metrics, and (opt-in) console. Cluster formation, disk and Ceph
administration, updates and certificates stay in the Proxmox UI — see the
non-goals in the plan.

## Planned quick start

Node 26 is required, not merely recommended — `npm install` refuses to run on
anything else. `.nvmrc` pins it.

```bash
nvm use                   # Node 26, per .nvmrc
cp .env.example .env      # then set PVE_HOST, PVE_TOKEN_ID, PVE_TOKEN_SECRET
docker compose up -d      # redis + postgres
npm install
npm run migrate
npm run pve:check         # verifies reachability, TLS, and token permissions
npm run dev               # api on :8080
npm run dev:worker        # polling, task following, metrics
```

Mint a key for your first consumer:

```bash
npm run key:create -- --name deploy-bot --scopes read,operate
```

The plaintext key is printed once and never stored — only its sha256 is.

```bash
curl -H "Authorization: Bearer npx_..." http://localhost:8080/v1/guests
```

### Setting up the Proxmox side

Create a privilege-separated token rather than reusing `root@pam`:

```bash
pveum user add ninja@pve
pveum user token add ninja@pve ctl --privsep 1
pveum acl modify /       --user  ninja@pve   --role PVEAuditor
pveum acl modify /vms    --token 'ninja@pve!ctl' --role PVEVMAdmin
pveum acl modify /storage --token 'ninja@pve!ctl' --role PVEDatastoreUser
```

A token with `--privsep 1` starts with **no** permissions even if its user is
root — the grant above is not optional. `npm run pve:check` reports which
planned features the current token cannot perform, so gaps show up on a
checklist rather than as a 403 mid-incident.

## Security

This service holds a credential that can destroy every guest in the cluster. It
belongs on your management network, not the public internet; the compose file
binds to localhost by default. Do not run it on a node it manages — a
`node.reboot` that reboots its own host has an obvious ending, and the service
warns at boot if it detects this.

TLS to Proxmox defaults to full verification. For the usual self-signed
homelab certificate, use `PVE_TLS_MODE=pin` with a fingerprint rather than
disabling verification; `PVE_TLS_MODE=insecure` refuses to start in production.

## Layout

| Path | |
| --- | --- |
| `docs/ninja-proxmox-plan.md` | The design: constraints, architecture, API contract, safety model, phases |
| `docs/proxmox-api-surface.md` | Every upstream Proxmox call we depend on |
| `src/` | Service and worker (not yet written) |
| `public/` | Single-file web UI, no build step |

## Licence

GPL-2.0-only.
