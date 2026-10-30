# n8nDemo

A reproducible [n8n](https://n8n.io) Community Edition sandbox. Clone the
repository on any macOS or Linux machine, run one script, get a working n8n.

---

## 1. Purpose

This repository exists so that an n8n instance can be stood up — and torn down
again cleanly — without hand-crafted `docker run` commands or undocumented
local state.

What it gives you:

- **n8n Community Edition** in a single Docker container, SQLite storage.
- **Pinned version.** The image tag lives in `.env`, never `latest`, so the
  same clone produces the same stack tomorrow.
- **A defined host interface directory**, `$HOME/docker/n8n_data`, split into
  internal state and a file-exchange area.
- **Loopback-only exposure.** UI, REST API and webhooks on `127.0.0.1:5678`.
  Nothing is reachable from your LAN.
- **A shared Docker network** so other containerised services can be wired in
  and called from workflows by name.
- **Reversibility.** `./n8n.sh destroy --purge-data` removes every artefact
  this project creates on the host. Section 4 lists them explicitly.

Scope: local experimentation and learning. This is not a production
deployment — no reverse proxy, no TLS, no external database, no queue mode.

### Licensing

n8n is released under the [Sustainable Use License](https://docs.n8n.io/sustainable-use-license/),
not an OSI-approved open-source licence. It is free for internal business use
and personal use; reselling it or offering it as a hosted service to third
parties is not permitted. Check the licence if your use case is commercial.

---

## 2. Deployment

### Prerequisites

| Requirement | Notes |
|---|---|
| Docker Engine with the Compose **v2** plugin | `docker compose version` must work. The legacy `docker-compose` binary is not supported. |
| `openssl` | Used once to generate the encryption key. Present by default on macOS and most Linux distributions. |
| macOS or Linux | Tested on macOS (Apple Silicon, Docker Desktop) and Linux x86_64. |
| Free TCP port 5678 on loopback | Change `N8N_PORT` in `.env` if it is taken. |

### Install

```bash
git clone https://github.com/dflegl/n8nDemo.git
cd n8nDemo
./bootstrap.sh
```

`bootstrap.sh` is idempotent — re-running it never overwrites an existing
`.env` and never touches existing data. It will:

1. Verify Docker, the Compose plugin and a reachable daemon.
2. Create `$HOME/docker/n8n_data/.n8n` and `$HOME/docker/n8n_data/files`
   (on Linux, `chown 1000:1000` so the container's `node` user can write).
3. Generate `.env` from `.env.example`, filling in the absolute data path and
   a random `N8N_ENCRYPTION_KEY` (`openssl rand -hex 32`), mode `600`.
4. Create the external Docker network `n8n_shared` if it does not exist.
5. `docker compose up -d` and wait until the healthcheck reports healthy.

### First run

Open **http://127.0.0.1:5678** and create the owner account. It is stored
locally in the SQLite database; no registration leaves your machine.

### Back up the encryption key — do this now

`N8N_ENCRYPTION_KEY` in `.env` encrypts every credential n8n stores. Copy the
value into your password manager:

```bash
grep N8N_ENCRYPTION_KEY .env
```

Two things worth knowing:

- The key must stay matched to the data. n8n gives the environment variable
  precedence, so pointing a different `N8N_ENCRYPTION_KEY` at an existing
  database makes every stored credential fail to decrypt.
- The key is also written to `$HOME/docker/n8n_data/.n8n/config` in plain text.
  That file is inside every `./n8n.sh backup` archive, which is why those
  archives are secrets — see [Backup and restore](#backup-and-restore).

### Publishing this repository to GitHub

```bash
gh auth login --hostname github.com --web   # sign in as the target account
./scripts/github-init.sh dflegl n8nDemo
```

The script sets `user.name` and `user.email` **for this repository only**
(`git config` without `--global`), so a work identity configured globally is
left alone.

Manual alternative, if you would rather not use `gh`:

```bash
git config user.name  "David Flegl"
git config user.email "david.flegl@email.cz"
git add -A && git commit -m "Initial commit"
git remote add origin https://github.com/dflegl/n8nDemo.git
git push -u origin main
```

---

## 3. Usage

### Control script

```bash
./n8n.sh up                 # start
./n8n.sh down               # stop, keep all data
./n8n.sh restart            # recreate the container (after editing .env)
./n8n.sh status             # state, health, networks, data size
./n8n.sh logs -f            # follow logs
./n8n.sh shell              # shell inside the container
./n8n.sh url                # print the local URL
./n8n.sh backup             # archive the data directory to ./backups/
./n8n.sh restore <file>     # restore an archive (destructive, confirms)
./n8n.sh destroy            # remove container, image, compose network
./n8n.sh destroy --purge-data   # the above plus the host data directory
```

### File exchange between host and workflows

The interface directory is split so that n8n's internal database does not get
mixed up with the files you care about:

| Host path | Container path | Contents |
|---|---|---|
| `$HOME/docker/n8n_data/.n8n` | `/home/node/.n8n` | SQLite database, encryption key, logs. Treat as opaque. |
| `$HOME/docker/n8n_data/files` | `/data/files` | **Your exchange area.** Anything you drop here is immediately visible to workflows, and anything a workflow writes appears here. |

In a workflow, use the **Read/Write Files from Disk** node against paths under
`/data/files/`. Nothing else on your host is visible to the container.

### REST API and webhooks

Full details and `curl` examples: **[docs/API.md](docs/API.md)**.

Short version — create an API key in **Settings → n8n API**, then:

```bash
curl -s http://127.0.0.1:5678/api/v1/workflows \
  -H "X-N8N-API-KEY: $N8N_API_KEY"
```

Webhooks come in two flavours: `/webhook-test/<path>` (editor open, single
request) and `/webhook/<path>` (workflow active, permanent).

### Example workflow

Import `examples/workflows/hello-webhook.json` via **Workflows → Import from
File**. It accepts a POST, writes a timestamped JSON file into the exchange
directory, and returns the path. Verify with:

```bash
ls -l "$HOME/docker/n8n_data/files/"
```

### Connecting other containers

Any stack can be made visible to n8n by joining the external `n8n_shared`
network:

```yaml
services:
  my-service:
    image: my/image
    networks: [n8n_shared]

networks:
  n8n_shared:
    name: n8n_shared
    external: true
```

n8n then reaches it by **service name on its container port** — no host port
mapping needed:

```
http://my-service:8080/
```

A ready-made demonstration lives in `examples/sidecar-service/`:

```bash
cd examples/sidecar-service && docker compose up -d
# then from an HTTP Request node in n8n:
#   http://whoami/            (whoami listens on 80)
#   http://httpbin:8080/get   (go-httpbin listens on 8080)
```

Note the port: it is the container's own port, not a host port. Neither example
service publishes anything to the host.

### Reaching services on the host

`host.docker.internal` resolves to your host from inside the container:

```
http://host.docker.internal:8080
```

On Docker Desktop for macOS this reaches host services even when they are bound
to `127.0.0.1`.

> **Security note.** This setup applies no egress restrictions: workflows can
> reach the internet, your LAN and your host's services. Combined with Code and
> Execute Command nodes, an imported workflow can do anything a program on your
> machine could do over the network. Read workflows before running them, keep
> the port on loopback, and do not store production credentials here.
> [docs/NETWORKING.md](docs/NETWORKING.md) explains the boundaries in detail —
> including what is *not* reachable (your filesystem, the Docker socket) and
> how to add real egress filtering if you want it.

### Upgrading n8n

```bash
# edit N8N_VERSION in .env, then:
./n8n.sh backup
./n8n.sh restart
```

Take the backup first: n8n migrates its database schema on startup, and
migrations are not reversible.

### Backup and restore

```bash
./n8n.sh backup
# -> ./backups/n8n-data-YYYYmmdd-HHMMSS.tar.gz
```

The container is stopped for the duration so the SQLite snapshot is consistent,
then restarted.

> **Treat backup archives as secrets.** They contain `.n8n/config`, which holds
> `N8N_ENCRYPTION_KEY` in plain text, alongside the encrypted credential blobs
> in `database.sqlite`. Anyone with the archive has both halves. Do not commit
> one, do not drop one in a shared folder. `backups/` is git-ignored for this
> reason.

```bash
./n8n.sh restore ./backups/n8n-data-20260101-120000.tar.gz
```

`restore` requires typing `RESTORE` to confirm, then replaces the data
directory. Afterwards it compares the key inside the archive against the one in
`.env` and, if they differ, prints the archive's key so you can put it in
`.env` and `./n8n.sh restart`.

---

## 4. Teardown and full cleanup

### What this project creates on your host

| # | Artefact | Location | Removed by |
|---|---|---|---|
| 1 | Container `n8n` | Docker | `./n8n.sh down` |
| 2 | Image `docker.n8n.io/n8nio/n8n:<version>` | Docker | `./n8n.sh destroy` |
| 3 | Network `n8n_net` | Docker | `./n8n.sh destroy` |
| 4 | Network `n8n_shared` | Docker | `./n8n.sh destroy`, **only if no containers are attached** |
| 5 | Data directory | `$HOME/docker/n8n_data` | `./n8n.sh destroy --purge-data` |
| 6 | `.env` | repository root | `./n8n.sh destroy --purge-data` |
| 7 | Backup archives | `./backups/` | manual — never deleted automatically |
| 8 | Example containers `whoami`, `httpbin` | Docker | `cd examples/sidecar-service && docker compose down` |

Nothing is installed outside Docker and `$HOME/docker/n8n_data`. No system
packages, no launch agents, no systemd units, no changes to your global git
configuration.

### Pause (keep everything)

```bash
./n8n.sh down
```

Removes the container. Workflows, credentials, executions and the encryption
key all survive. `./n8n.sh up` brings it back exactly as it was.

### Full removal

```bash
# stop any example stacks first
cd examples/sidecar-service && docker compose down && cd -

./n8n.sh destroy --purge-data
```

Two confirmations are required: typing `DESTROY`, then `DELETE-DATA`. This
permanently deletes all workflows, credentials and execution history.

Optionally remove the leftovers:

```bash
rm -rf ./backups                 # local backup archives
rm -rf "$HOME/docker/n8n_data"   # only if you skipped --purge-data
cd .. && rm -rf n8nDemo          # the clone itself
```

### Manual fallback

If the scripts are unavailable, the same cleanup by hand:

```bash
docker rm -f n8n whoami httpbin 2>/dev/null
docker network rm n8n_net n8n_shared 2>/dev/null
docker image rm docker.n8n.io/n8nio/n8n:1.123.91 2>/dev/null
rm -rf "$HOME/docker/n8n_data"
```

### Verifying nothing is left

```bash
docker ps -a --filter name=n8n
docker network ls | grep n8n
docker images | grep n8n
ls -la "$HOME/docker/"
```

All four should come back empty of n8n artefacts.

---

## Repository layout

```
n8nDemo/
├── README.md                     this file
├── .env.example                  environment template (committed)
├── .env                          generated by bootstrap.sh (git-ignored)
├── docker-compose.yml            the n8n service definition
├── bootstrap.sh                  one-shot setup
├── n8n.sh                        day-to-day control
├── scripts/
│   ├── lib.sh                    shared shell helpers
│   └── github-init.sh            publish this repo to GitHub
├── docs/
│   ├── NETWORKING.md             what n8n can and cannot reach
│   ├── API.md                    REST API and webhook reference
│   └── REBUILD_PROMPT.md         AI prompt that recreates this repository
└── examples/
    ├── sidecar-service/          a second stack n8n can call
    └── workflows/                importable example workflow
```

`docs/REBUILD_PROMPT.md` is a self-contained specification written as a prompt:
hand it to an AI assistant and it will reconstruct this repository from
scratch. It is written in Czech; everything else here is English.
