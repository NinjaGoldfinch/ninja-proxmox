# The Proxmox API surface we depend on

Companion to [ninja-proxmox-plan.md](ninja-proxmox-plan.md). One row per
upstream call we intend to make, so the client module (`src/pve/endpoints.ts`)
has a checklist and so a PVE upgrade has a blast-radius list.

Base: `https://{node}:8006/api2/json`. Auth on every call:
`Authorization: PVEAPIToken={user}@{realm}!{tokenid}={uuid}`. No
`CSRFPreventionToken` is needed under token auth.

**Async** marks calls that return a UPID rather than a result (plan §3 C1) —
these go through the task orchestrator, never straight back to a caller.

## Discovery and health

| Method | Path | Used for | Async |
| --- | --- | --- | --- |
| GET | `/version` | Version, and the boot-time self-host check (§18) | |
| GET | `/cluster/status` | Node membership, quorum, cluster name | |
| GET | `/cluster/resources` | **The firehose.** Every node, guest, storage, pool with live status. `?type=vm\|node\|storage\|sdn` | |
| GET | `/access/permissions` | `pve:check` — what our token may actually do (§10.4) | |
| GET | `/nodes` | Node list with status and uptime | |
| GET | `/nodes/{node}/status` | CPU, memory, root fs, kernel, load | |

## Guests — shared

`{kind}` is `qemu` or `lxc`. Where the two differ, the row says so.

| Method | Path | Used for | Async |
| --- | --- | --- | --- |
| GET | `/nodes/{node}/{kind}/{vmid}/status/current` | Live status, lock, HA, uptime, `qmpstatus` | |
| GET | `/nodes/{node}/{kind}/{vmid}/config` | Config read; `?current=1` for the running values | |
| PUT | `/nodes/{node}/{kind}/{vmid}/config` | Allow-listed edits with `digest` (§11.4). **Returns UPID when running, `null` when stopped** (C10) | ◐ |
| GET | `/nodes/{node}/{kind}/{vmid}/rrddata` | Charts. `?timeframe=hour\|day\|week\|month\|year&cf=AVERAGE` | |
| DELETE | `/nodes/{node}/{kind}/{vmid}` | Destroy. `?purge=1&destroy-unreferenced-disks=1` | ● |
| POST | `/nodes/{node}/{kind}/{vmid}/status/start` | | ● |
| POST | `/nodes/{node}/{kind}/{vmid}/status/stop` | Hard power-off | ● |
| POST | `/nodes/{node}/{kind}/{vmid}/status/shutdown` | ACPI/graceful. `?timeout=&forceStop=1` | ● |
| POST | `/nodes/{node}/{kind}/{vmid}/status/reboot` | | ● |
| POST | `/nodes/{node}/qemu/{vmid}/status/reset` | QEMU only — hard reset | ● |
| POST | `/nodes/{node}/{kind}/{vmid}/status/suspend` | QEMU takes `?todisk=1`; LXC support is narrower | ● |
| POST | `/nodes/{node}/{kind}/{vmid}/status/resume` | | ● |
| POST | `/nodes/{node}/{kind}/{vmid}/clone` | `newid`, `name`, `full`, `target`, `storage` | ● |
| POST | `/nodes/{node}/{kind}/{vmid}/migrate` | `target`, `online`/`restart`, `with-local-disks` | ● |
| GET | `/nodes/{node}/qemu/{vmid}/migrate` | **Preconditions** — local disks, local resources, allowed targets (§11.3) | |
| POST | `/nodes/{node}/{kind}/{vmid}/template` | One-way conversion | ● |

## Snapshots

| Method | Path | Used for | Async |
| --- | --- | --- | --- |
| GET | `/nodes/{node}/{kind}/{vmid}/snapshot` | Snapshot list with parents | |
| POST | `/nodes/{node}/{kind}/{vmid}/snapshot` | `snapname`, `description`; QEMU also `vmstate` | ● |
| DELETE | `/nodes/{node}/{kind}/{vmid}/snapshot/{name}` | | ● |
| POST | `/nodes/{node}/{kind}/{vmid}/snapshot/{name}/rollback` | | ● |
| GET/PUT | `/nodes/{node}/{kind}/{vmid}/snapshot/{name}/config` | Snapshot description | |

## Backup and restore

| Method | Path | Used for | Async |
| --- | --- | --- | --- |
| POST | `/nodes/{node}/vzdump` | Ad-hoc backup. `vmid`, `storage`, `mode=snapshot\|suspend\|stop`, `compress`, `notes-template` | ● |
| GET | `/cluster/backup` | Scheduled job definitions | |
| GET | `/cluster/backup-info/not-backed-up` | Guests no job covers — a genuinely useful UI panel | |
| GET | `/nodes/{node}/storage/{storage}/content?content=backup` | The archive index | |
| DELETE | `/nodes/{node}/storage/{storage}/content/{volume}` | Delete an archive | ● |
| POST | `/nodes/{node}/{kind}` | **Restore** — create with `archive={volid}`, `vmid`, `force`, `storage` | ● |

## Storage

| Method | Path | Used for | Async |
| --- | --- | --- | --- |
| GET | `/storage` | Cluster-wide storage definitions | |
| GET | `/nodes/{node}/storage` | Per-node storage with usage and `active` | |
| GET | `/nodes/{node}/storage/{storage}/content` | Volumes, ISOs, templates, backups | |
| GET | `/nodes/{node}/storage/{storage}/status` | Capacity for preflight (§11.3) | |

## Tasks

| Method | Path | Used for | Async |
| --- | --- | --- | --- |
| GET | `/nodes/{node}/tasks/{upid}/status` | The follower's hot call (§7.3) | |
| GET | `/nodes/{node}/tasks/{upid}/log` | `?start=&limit=` — stored tail on completion | |
| DELETE | `/nodes/{node}/tasks/{upid}` | Best-effort cancel; not every worker honours it | |
| GET | `/nodes/{node}/tasks` | **Reconciliation** (§7.4): `?vmid=&typefilter=&userfilter=&since=&limit=` | |
| GET | `/cluster/tasks` | Recent cluster-wide tasks, including ones we did not submit | |

## QEMU guest agent

Optional; every call is guarded by the guest's `agent` config flag and fails
softly when the agent is absent.

| Method | Path | Used for |
| --- | --- | --- |
| GET | `/nodes/{node}/qemu/{vmid}/agent/get-osinfo` | OS name in the UI |
| GET | `/nodes/{node}/qemu/{vmid}/agent/network-get-interfaces` | Guest IPs — the most-asked-for field the projection lacks |
| POST | `/nodes/{node}/qemu/{vmid}/agent/ping` | Agent liveness |

## HA and replication (read-only in v1)

| Method | Path | Used for |
| --- | --- | --- |
| GET | `/cluster/ha/resources` | Which guests are HA-managed — gates node power actions (§11.3) |
| GET | `/cluster/ha/status/current` | HA state per resource |
| GET | `/cluster/replication` | Replication jobs and their last result |

## Node power

Admin scope, always confirmed (§11.2).

| Method | Path | Used for | Async |
| --- | --- | --- | --- |
| POST | `/nodes/{node}/status` | `command=reboot\|shutdown` | ● |

## Console — opt-in module only (C3)

**These are the only calls in the service that use a ticket rather than the API
token**, and they live behind `CONSOLE_ENABLED`. See plan §15.

| Method | Path | Used for |
| --- | --- | --- |
| POST | `/access/ticket` | Mint/refresh a `PVEAuthCookie` ticket + CSRF token |
| POST | `/nodes/{node}/{kind}/{vmid}/vncproxy` | Port + vncticket for a VNC session |
| POST | `/nodes/{node}/{kind}/{vmid}/termproxy` | Port + ticket for a serial/xterm session |
| GET | `/nodes/{node}/{kind}/{vmid}/vncwebsocket` | The upgrade. `?port=&vncticket=`. **Rejects token auth** — needs the cookie |
| POST | `/nodes/{node}/{kind}/{vmid}/spiceproxy` | SPICE connection file, if we support it |

## Not used

Recorded so the boundary is explicit, not accidental: `/cluster/config` (node
join/leave), `/nodes/{node}/disks/*`, `/nodes/{node}/ceph/*`,
`/nodes/{node}/apt/*`, `/nodes/{node}/certificates/*`, `/access/users` and
`/access/acl` writes, `/nodes/{node}/execute`, and anything under
`/nodes/{node}/firewall` beyond reads. These are cluster administration, and
plan §1 says that stays in the Proxmox UI.
