# CLAUDE.md

Guidance for Claude Code and anyone else working in this repo.

## The project

`ninja-proxmox` — a control plane in front of one Proxmox VE cluster. A Fastify
API and a no-build-step web UI over the Proxmox API. Two processes: `src/index.ts`
serves, `src/worker.ts` polls and follows tasks.

**Read [docs/ninja-proxmox-plan.md](docs/ninja-proxmox-plan.md) before writing
code.** Several design decisions are forced by Proxmox behaviour that looks like
over-engineering until you know why. They are numbered `C1`–`C11` in §3 of that
document and cited from the code.

The four that catch everyone:

- **C1 — a mutation returns a UPID, not a result.** `200` means a worker was
  forked. Never report success from a mutation's HTTP response.
- **C2 — `pvedaemon` has three workers.** All upstream calls go through the
  governor in `src/pve/governor.ts`. Never call `src/pve/client.ts` around it.
- **C3 — API tokens cannot authenticate `/vncwebsocket`.** Only `src/console/`
  touches tickets, and only when `CONSOLE_ENABLED`.
- **C11 — there is no upstream idempotency key.** Never blind-retry a write.
  Reconcile through `src/tasks/` instead.

## Documentation is part of the change

A behaviour change and the doc update that reflects it belong in the same
commit.

| If you change… | Update… |
| --- | --- |
| `src/pve/` | plan §5–6, and `docs/proxmox-api-surface.md` if the set of upstream calls changed |
| `src/tasks/` | plan §7 — the sequence diagram and the state list |
| `src/policy/`, `src/audit/` | plan §10–11 |
| `src/routes/` | plan §9 route tables |
| `src/state/`, the poller | plan §8 |
| `src/console/` | plan §15 |
| `src/db/schema.ts` or a migration | plan §12 |
| A config variable | plan §16 **and** `.env.example` **and** the env file written by `deploy/provision-ninja-proxmox-lxc.sh` |
| `deploy/*.sh` | `deploy/README.md`, and plan §18 if the deployment shape changed |
| A decision, constraint or trade-off | plan §2, §3 or §20 |

Do not duplicate prose between README and the plan — link instead.

### Diagrams

Mermaid in fenced ` ```mermaid ` blocks. GitHub renders it natively and it
diffs as text.

## Working in this repo

- Node 26, pinned in `.nvmrc` with `engine-strict=true`.
- TypeScript strict; TypeBox schemas on every route and on every upstream
  response shape.
- `npm run typecheck && npm run lint && npm test` before you call something
  done.
- Tests that need Proxmox use the simulator in `test/fake-pve/`, never a real
  cluster. Acceptance tests against real hardware are opt-in and gated on
  `ACCEPTANCE_PVE_HOST`.
- Work is tracked in GitHub issues, not in a `TODO.md`.

## Things not to do

- Do not add a generic Proxmox passthrough route. It is an open question in
  plan §20 and the current answer is no.
- Do not allow-list `args` or `hookscript` in config edits. Both are arbitrary
  code execution on the host (plan §11.4).
- Do not widen `CONFIG_ALLOWED_KEYS` without a note in plan §11.4.
- Do not disable TLS verification as a convenience. `PVE_TLS_MODE=pin` exists
  for exactly that itch.
