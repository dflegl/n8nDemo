# Prompt for recreating this repository

This file is a **self-contained prompt**. Copy everything below the
`=== PROMPT START ===` marker and paste it into an AI assistant (Claude,
ChatGPT, Copilot, Cursor, …). The result is a working copy of this repository.

---

=== PROMPT START ===

Create a repository called `n8nDemo` — a reproducible sandbox for n8n Community
Edition running in Docker. The goal: clone the repository on any macOS or Linux
machine, run a single script, get a working n8n — and be able to remove it
again without leaving traces.

## Language

Write all file contents — code, comments, README, documentation, commit
messages — in **English**. No exceptions, including this prompt file itself.

## Target environment

- macOS (Apple Silicon and Intel) and Linux x86_64
- Docker Engine with the **Compose v2** plugin (`docker compose`, not
  `docker-compose`)
- Shell scripts in `bash`, portable between macOS (BSD userland) and Linux (GNU
  userland) — mind the differences in `sed -i`, `stat`, `readlink -f`

## Architecture to implement

### Container

A single container running n8n Community Edition:

- image `docker.n8n.io/n8nio/n8n:${N8N_VERSION}`, with the version **pinned**
  (`1.123.91` at the time of writing), never `latest`
- **SQLite** storage (the n8n default), no Postgres
- port published on **loopback only**: `127.0.0.1:${N8N_PORT}:5678`
- healthcheck against `/healthz` using `wget` — the image is Alpine/BusyBox
  based and `curl` is not guaranteed to be present

Required environment variables:

| Variable | Value | Why |
|---|---|---|
| `N8N_HOST` | `localhost` | |
| `N8N_PORT` | `5678` | internal port |
| `N8N_PROTOCOL` | `http` | |
| `WEBHOOK_URL` | `http://localhost:${N8N_PORT}/` | base URL for production webhooks |
| `N8N_SECURE_COOKIE` | `false` | n8n otherwise refuses to set its auth cookie over plain HTTP |
| `DB_TYPE` | `sqlite` | |
| `N8N_ENCRYPTION_KEY` | from `.env` | credential encryption |
| `GENERIC_TIMEZONE`, `TZ` | `Europe/Prague` | |
| `N8N_PUBLIC_API_DISABLED` | `false` | enables the REST API at `/api/v1` |
| `N8N_RUNNERS_ENABLED` | `true` | the supported execution model for Code nodes |
| `NODE_FUNCTION_ALLOW_BUILTIN` | `*` | |
| `NODE_FUNCTION_ALLOW_EXTERNAL` | `*` | |
| `N8N_BLOCK_ENV_ACCESS_IN_NODE` | `true` | Code nodes must not read env vars, hence not the encryption key |
| `N8N_DIAGNOSTICS_ENABLED` | `false` | |
| `N8N_VERSION_NOTIFICATIONS_ENABLED` | `false` | |
| `N8N_HIRING_BANNER_ENABLED` | `false` | |

Security settings that cost nothing in terms of experimentation:

- `security_opt: [no-new-privileges:true]`
- `cap_drop: [ALL]`
- **never** mount `/var/run/docker.sock` (it is equivalent to root on the host)
- `extra_hosts: ["host.docker.internal:host-gateway"]` — host access **is**
  intended here; this line is required on Linux

### Host storage

Interface directory `$HOME/docker/n8n_data`, split into two subdirectories so
that n8n's internal state does not get mixed with user files:

| Host | Container | Contents |
|---|---|---|
| `$HOME/docker/n8n_data/.n8n` | `/home/node/.n8n` | SQLite DB, encryption key, logs |
| `$HOME/docker/n8n_data/files` | `/data/files` | file exchange, host ↔ workflows |

### Networks

| Network | Type | Purpose |
|---|---|---|
| `n8n_net` | Compose-managed, bridge | default egress, NAT to the internet |
| `n8n_shared` | **`external: true`**, created by `bootstrap.sh` | container-to-container traffic across stacks |

`n8n_shared` must be external so that `./n8n.sh destroy` cannot remove the
network out from under unrelated stacks attached to it.

### Isolation — a deliberate decision

No egress restrictions. n8n may reach the internet, the LAN, and host services
via `host.docker.internal`. This is a sandbox meant for experimentation.

Boundaries that hold regardless, and which the documentation must state
**clearly**:

- the host filesystem is **not** visible, apart from the two bind mounts above
- the Docker daemon is **not** reachable, because the socket is not mounted

In `docs/NETWORKING.md`, additionally describe an optional recipe for real
isolation using a **network sidecar** (a container with `NET_ADMIN` that owns
the network namespace and applies iptables rules; n8n joins it via
`network_mode: service:<sidecar>`). Include the trade-offs: RFC1918 rules break
container-to-container traffic unless ACCEPT rules for `n8n_shared` and for the
embedded DNS resolver `127.0.0.11` are placed before the REJECT rules.

## Files to create

```
n8nDemo/
├── README.md
├── .gitignore
├── .env.example
├── docker-compose.yml
├── bootstrap.sh                  (executable)
├── n8n.sh                        (executable)
├── scripts/
│   ├── lib.sh
│   └── github-init.sh            (executable)
├── docs/
│   ├── NETWORKING.md
│   ├── API.md
│   └── REBUILD_PROMPT.md
└── examples/
    ├── sidecar-service/docker-compose.yml
    └── workflows/hello-webhook.json
```

### `.gitignore`

Ignore `.env`, `backups/`, `.DS_Store`, editor directories.

### `.env.example`

A commented template with `N8N_VERSION`, `N8N_PORT`, `N8N_DATA_DIR`,
`N8N_ENCRYPTION_KEY`, `GENERIC_TIMEZONE`. Placeholders for the path and the key
which `bootstrap.sh` substitutes. Warn next to the encryption key that
credentials are unrecoverable without it.

### `scripts/lib.sh`

Shared functions, sourced only, never executed:

- coloured `log`/`ok`/`warn`/`die`, colours disabled when stdout is not a TTY
- `detect_os` → `macos` | `linux`, otherwise `die`
- `require_cmd <cmd> [hint]`
- `require_docker` — verifies the CLI, the Compose v2 plugin and daemon
  reachability
- `env_get <file> <key>` — reads a single key from an env file **without**
  sourcing it
- `confirm_word <word> <prompt>` — confirmation by typing an exact word

### `bootstrap.sh`

Idempotent, `set -euo pipefail`. Never overwrites an existing `.env` and never
touches existing data.

1. **Preflight**: `require_docker`, `require_cmd openssl`
2. **Directories**: take the target path from an existing `.env` if present (so
   a re-run never relocates data), otherwise `$HOME/docker/n8n_data`. Create
   `.n8n/` and `files/`. **On Linux** `chown 1000:1000` (the `node` user in the
   image), with a `sudo` fallback and a clear error message. On macOS Docker
   Desktop handles this — do not do it there.
3. **`.env`**: generate it from the template using `sed` with `|` as the
   delimiter (the path contains `/`), fill in the absolute `N8N_DATA_DIR` and
   `N8N_ENCRYPTION_KEY=$(openssl rand -hex 32)`, `chmod 600`, and print a
   warning about backing up the key.
4. **Port check**: if our own `n8n` container is not already running and the
   port is taken (`lsof`), exit with advice to change `N8N_PORT`.
5. **Network**: `docker network create n8n_shared` unless it exists.
6. **Start**: `docker compose up -d`, then actively poll for the `healthy`
   state via `docker inspect -f '{{.State.Health.Status}}'`, timeout 180 s. On
   `unhealthy` or timeout, print the last 40 log lines and exit with an error.
7. Closing summary: URL, host paths, pointer to `./n8n.sh`.

### `n8n.sh`

A single control script with these commands:

| Command | Behaviour |
|---|---|
| `up` | ensure `n8n_shared` exists, `docker compose up -d` |
| `down` | `docker compose down`, data preserved |
| `restart` | `docker compose up -d --force-recreate` |
| `status` | `compose ps`, health, attached networks with IPs, `du -sh` of the data directory |
| `logs [-f]` | last 200 lines, or follow |
| `shell` | `docker exec -it n8n /bin/sh` |
| `url` | print `http://127.0.0.1:<port>` |
| `backup` | **stop the container** (consistent SQLite snapshot), `tar -czf` the data directory into `./backups/n8n-data-<timestamp>.tar.gz`, restart only if it was running; warn that the archive is a **secret** — see below |
| `restore <file>` | confirm with the word `RESTORE`, `compose down`, delete the data directory, extract the archive, chown on Linux, compare keys (see below), `up` |
| `destroy [--purge-data]` | confirm `DESTROY` → `compose down --volumes --remove-orphans`, remove the image; remove `n8n_shared` **only if no containers are attached**. With `--purge-data`, a second confirmation `DELETE-DATA` and deletion of the data directory and `.env` |
| `help` | usage text |

Every data-touching command must first verify `.env` exists and otherwise point
at `./bootstrap.sh`.

**Important fact about the encryption key — do not miss this:** n8n writes the
encryption key into `.n8n/config` as **plain-text JSON**. The backup archive
therefore contains it, alongside the encrypted credentials in
`database.sqlite`. Do not claim anywhere that "the key is not in the archive";
that is false. Instead:

- in `backup`, warn that the archive is a secret and belongs in `backups/`,
  which is git-ignored
- in `restore`, after extraction **compare** the key from `.n8n/config` against
  `N8N_ENCRYPTION_KEY` in `.env`; on mismatch, print the archive's key and
  instruct the user to put it in `.env` and run `./n8n.sh restart`. n8n gives
  the environment variable precedence over the file, so a mismatch means
  undecryptable credentials.

### `scripts/github-init.sh`

Publishing to GitHub, parameters `[owner] [repo-name]`, defaults
`dflegl n8nDemo`, visibility **public**.

- set `git config user.name/user.email` **locally in the repository** (without
  `--global`) so that a globally configured work identity is left alone
- check `gh auth status`; if the target account is missing, **do not fail
  silently** — print a plain `gh auth login` instruction plus the
  `gh auth login --with-token` alternative for headless machines, list the
  already-authenticated accounts, and exit with an error. Do not put
  `--hostname github.com` or `--web` in the suggested command: both are gh
  defaults, and hardcoding `--web` steers headless users away from token auth.
- `gh auth switch --hostname github.com --user <owner>` if the active account
  is not the target one
- create an initial commit if the repository has none; refuse to continue if
  there are uncommitted changes
- handle **all three** starting states, so the script is safe to re-run:
  1. `origin` already configured → use it
  2. the repo exists on GitHub but there is no `origin` → `git remote add` and
     push. This is the state after the user creates the repo by hand, and
     omitting it makes a failed run impossible to recover from.
  3. the repo does not exist → `gh repo create`, then add the remote
- keep repository creation and `git push` as **separate steps**; do not use
  `gh repo create --source=. --push`. When creation fails there is no remote to
  retry against, and the combined form hides which half failed.
- creation can legitimately fail on permissions. A **fine-grained PAT cannot
  create repositories** unless it grants `Administration: write`; classic
  tokens need the `repo` scope. Do not let the raw GraphQL error
  (`Resource not accessible by personal access token (createRepository)`)
  reach the user — catch it and print both ways forward: create the repo by
  hand at https://github.com/new and re-run, or re-authenticate. Likewise, if
  the push fails, mention that fine-grained tokens additionally need
  `Contents: write` on the repository.
- note that `gh auth status` prints no `Token scopes:` line for fine-grained
  PATs, so the presence of an account says nothing about what it may do

### `examples/sidecar-service/docker-compose.yml`

Two containers with no published ports, attached to the external `n8n_shared`
network: `traefik/whoami:v1.10` (listens on 80) and
`mccutchen/go-httpbin:2.26.0` (listens on **8080**).

Use `mccutchen/go-httpbin`, not `kennethreitz/httpbin` — the latter is
amd64-only and runs under emulation on Apple Silicon, producing a platform
mismatch warning.

In the comments, explain that n8n calls these by service name
(`http://whoami/`, `http://httpbin:8080/get`), not via localhost, and that the
port is the container's own port rather than a host mapping.

### `examples/workflows/hello-webhook.json`

An importable n8n workflow, valid JSON:

1. `n8n-nodes-base.webhook` (typeVersion 2) — POST, path `hello`,
   `responseMode: responseNode`
2. `n8n-nodes-base.code` (typeVersion 2) — wraps `$input.first().json.body`
   together with an ISO timestamp and a generated filename
3. `n8n-nodes-base.convertToFile` (typeVersion 1.1) — operation `toJson`
4. `n8n-nodes-base.readWriteFile` (typeVersion 1) — operation `write`, target
   path `/data/files/{{ ... }}`
5. `n8n-nodes-base.respondToWebhook` (typeVersion 1.1) — returns JSON with the
   path
6. `n8n-nodes-base.stickyNote` — an explanation on the canvas itself

Do not forget `connections`, `settings.executionOrder: "v1"` and a unique `id`
on every node.

### `docs/API.md`

- endpoint table: `/`, `/healthz`, `/api/v1/...`, `/webhook/...`,
  `/webhook-test/...`, plus a note that `/rest/...` is internal and unstable
- how to create an API key (Settings → n8n API), header `X-N8N-API-KEY`
- `curl` examples: list workflows, fetch one, executions, import a workflow
  from a file, activate/deactivate
- a note that the REST API has **no** endpoint for triggering a workflow run —
  webhooks are the supported mechanism
- the difference between `/webhook-test/` (editor open, single request) and
  `/webhook/` (workflow active, permanent), as a table
- calling a webhook from another container: `http://n8n:5678/...`, **not**
  `127.0.0.1`
- optional external exposure via `cloudflared tunnel --url
  http://127.0.0.1:5678` and the need to adjust `WEBHOOK_URL` plus
  `./n8n.sh restart`

### `docs/NETWORKING.md`

- an ASCII topology diagram
- a table of both networks
- what n8n **can** reach: the internet, other containers by DNS name, the host
  via `host.docker.internal` (on Docker Desktop for macOS this includes
  services bound to `127.0.0.1` only), the whole LAN
- what n8n **cannot** reach: the host filesystem beyond the two mounts, the
  Docker daemon
- a table of the hardening already applied and its effect
- a section on practical risk: workflows imported from the n8n template library
  run with exactly these permissions
- the optional iptables sidecar recipe including its drawbacks

### `README.md`

Exactly four top-level sections, in this order:

1. **Purpose** — what the repository is for, what it provides, an explicit
   scope statement (this is not production), and a licensing note about the
   Sustainable Use License (n8n is **not** OSI open source)
2. **Deployment** — prerequisites table, `git clone` + `./bootstrap.sh`, a
   description of what bootstrap does, first login, **a separate and prominent
   passage about backing up `N8N_ENCRYPTION_KEY`**, publishing to GitHub (both
   via the script and manually)
3. **Usage** — overview of `./n8n.sh` commands, file exchange with the mount
   table, REST API and webhooks pointing at `docs/API.md`, importing the
   example workflow, attaching another container with a copy-paste YAML
   snippet, host access **including a blockquote security warning**, upgrading
   the version, backup and restore
4. **Teardown & cleanup** — a table of **every artefact the project creates on
   the host** (container, image, two networks, data directory, `.env`,
   `backups/`, the example containers) stating what removes each; the
   difference between `down` (pause) and `destroy --purge-data` (removal);
   manual fallback commands; commands to verify nothing is left behind

Finish with a repository tree and a one-line description per file.

## Final verification

After creating everything, verify:

1. `bash -n` passes on every `.sh` file
2. `docker compose config` passes (with a temporary `.env`)
3. `examples/workflows/hello-webhook.json` is valid JSON
4. `./bootstrap.sh` reaches the healthy state
5. `curl -s http://127.0.0.1:5678/healthz` returns `{"status":"ok"}`
6. after `cd examples/sidecar-service && docker compose up -d`, running
   `wget -qO- http://whoami/` and `wget -qO- http://httpbin:8080/get` from
   inside the n8n container succeeds
7. `./n8n.sh backup` produces an archive and leaves the container running
8. `./n8n.sh status` lists both networks
9. `git status` is clean and `git check-ignore .env backups/` confirms both are
   excluded

=== PROMPT END ===

---

## Maintenance notes

When you change this repository, update the prompt above as well. The prompt is
a specification — once it drifts from reality it stops being useful.

Things most likely to change:

- **`N8N_VERSION`** — check the current stable tag on
  [Docker Hub](https://hub.docker.com/r/n8nio/n8n/tags). Note that n8n publishes
  more than one tag series; `stable` and `latest` pointed at `1.123.91` at the
  time of writing.
- **`typeVersion` values** in the example workflow — after a major n8n upgrade,
  confirm that importing it produces no warnings.
- **Environment variable names** — n8n occasionally renames them and deprecates
  the old ones. After an upgrade, check `./n8n.sh logs` for deprecation
  warnings.
