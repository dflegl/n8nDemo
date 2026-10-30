# Networking and isolation

What the n8n container can and cannot reach in this setup, why, and how to
tighten it if you ever want to.

## Topology

```
                   ┌──────────────────────── host (macOS / Linux) ────────────────────────┐
                   │                                                                      │
   127.0.0.1:5678 ─┼──► published port                                                    │
                   │                                                                      │
                   │   ┌─── n8n_net (bridge, NAT) ───┐    ┌─── n8n_shared (external) ──┐  │
                   │   │                             │    │                            │  │
                   │   │        ┌──────────┐         │    │   ┌────────┐  ┌─────────┐  │  │
                   │   │        │   n8n    │─────────┼────┼──►│ whoami │  │ httpbin │  │  │
                   │   │        └────┬─────┘         │    │   └────────┘  └─────────┘  │  │
                   │   └─────────────┼───────────────┘    └────────────────────────────┘  │
                   │                 │                                                    │
                   │                 ├──► host.docker.internal ──► host services           │
                   └─────────────────┼────────────────────────────────────────────────────┘
                                     │
                                     └──► internet (NAT)
```

Two networks, on purpose:

| Network      | Managed by  | Purpose |
|--------------|-------------|---------|
| `n8n_net`    | Compose     | Default egress. Gives the container NAT to the internet. Removed by `./n8n.sh destroy`. |
| `n8n_shared` | `bootstrap.sh`, declared `external: true` | Cross-stack traffic. Other `docker-compose.yml` files join it and n8n resolves them by service name. Declared external so that destroying n8n cannot tear the network out from under unrelated stacks. |

## What n8n CAN reach

This repository deliberately applies **no egress restrictions**. The container
is a sandbox meant for experimentation, so the following all work:

### The internet

Unrestricted. HTTP Request nodes, npm module downloads inside Code nodes, API
integrations — all fine.

### Other containers

Any container attached to `n8n_shared` is reachable by its **service name**,
on its **container port**, with no host port mapping involved:

```
http://whoami/            # whoami listens on 80
http://httpbin:8080/get   # go-httpbin listens on 8080
http://postgres:5432
```

The port is whatever the service listens on *inside* its container. Host port
mappings are irrelevant here — the example services publish nothing at all.

See `examples/sidecar-service/docker-compose.yml` for the pattern. The only
thing a foreign stack needs is:

```yaml
networks:
  n8n_shared:
    name: n8n_shared
    external: true
```

…plus `networks: [n8n_shared]` on each service that should be visible.

### Services running on the host

`docker-compose.yml` sets `extra_hosts: host.docker.internal:host-gateway`, so
workflows can call:

```
http://host.docker.internal:8080
http://host.docker.internal:5432
```

On Docker Desktop for macOS this reaches host services **even when they are
bound to `127.0.0.1` only**, because Docker Desktop proxies that address. On
Linux it maps to the bridge gateway IP, which reaches services bound to
`0.0.0.0` but not ones bound strictly to loopback.

### Your LAN

The container sits behind NAT with no egress filtering, so your router, NAS,
printers and other machines on the local network are all reachable by IP.

## What n8n CANNOT reach

### The host filesystem

Containers only see what is bind-mounted. Exactly two mounts exist:

| Host path                        | Container path   |
|----------------------------------|------------------|
| `$HOME/docker/n8n_data/.n8n`     | `/home/node/.n8n` |
| `$HOME/docker/n8n_data/files`    | `/data/files`     |

Nothing else on your disk is visible — not `$HOME`, not your SSH keys, not
other git repositories. This holds regardless of network configuration.

### The Docker daemon

`/var/run/docker.sock` is **not** mounted. This matters more than it looks:
mounting the Docker socket into a container is effectively granting it root on
the host, because it can start a new privileged container with `/` mounted.
Several n8n tutorials online suggest mounting it. Do not.

## Hardening that is already applied

These cost nothing and do not limit what you can experiment with:

| Setting | Effect |
|---------|--------|
| `ports: "127.0.0.1:5678:5678"` | The port is on loopback only. Nothing on your LAN can open the UI. |
| `N8N_BLOCK_ENV_ACCESS_IN_NODE=true` | Code nodes cannot read container environment variables, so a workflow cannot read `N8N_ENCRYPTION_KEY` and exfiltrate your credentials. |
| `cap_drop: ALL` | No Linux capabilities. No raw sockets, no mount, no network reconfiguration. |
| `security_opt: no-new-privileges:true` | setuid binaries inside the container cannot escalate. |
| non-root user (`node`, uid 1000) | Default in the n8n image; nothing in the compose file overrides it. |
| no `docker.sock` | See above. |

## Practical risk

The combination of *unrestricted egress* and *arbitrary code execution*
(Code nodes with `NODE_FUNCTION_ALLOW_EXTERNAL=*`, Execute Command nodes) means
a workflow can do anything a program on your machine could do over the network.

n8n ships a public template library. A template imported from the internet runs
with exactly these permissions.

Reasonable habits:

- Read a workflow before you run it, especially Code and HTTP Request nodes.
- Keep the port on `127.0.0.1`. Do not publish `0.0.0.0:5678` without auth.
- Do not store production credentials in a sandbox instance.
- Treat `$HOME/docker/n8n_data/files` as the only shared surface. Do not add
  more bind mounts "just to try something".

## Optional: actually blocking host and LAN access

Not enabled here, documented in case you want it later.

The reason this is non-trivial: a container with internet access always has a
route to the Docker bridge gateway, and that gateway *is* the host. Removing
`extra_hosts` only removes the convenient hostname — the IP is still routable.
Real blocking requires packet filtering inside the container's network
namespace, which needs `NET_ADMIN`, which the n8n container must not have.

The standard solution is a **network sidecar**: a tiny privileged container
owns the network namespace and installs the firewall rules; n8n then joins that
namespace and inherits them without holding the capability itself.

```yaml
services:
  netguard:
    image: alpine:3.20
    container_name: n8n-netguard
    cap_add: [NET_ADMIN]
    # n8n's port must be published here, because netguard owns the namespace.
    ports:
      - "127.0.0.1:5678:5678"
    command: >
      sh -c "apk add --no-cache iptables >/dev/null &&
             GW=$$(ip route | awk '/default/ {print $$3}') &&
             iptables -A OUTPUT -d $$GW -j REJECT &&
             iptables -A OUTPUT -d 10.0.0.0/8     -j REJECT &&
             iptables -A OUTPUT -d 172.16.0.0/12  -j REJECT &&
             iptables -A OUTPUT -d 192.168.0.0/16 -j REJECT &&
             sleep infinity"
    networks: [n8n_net]

  n8n:
    # Inherit netguard's network namespace. Note that `ports`, `networks` and
    # `extra_hosts` must then be removed from this service - they are owned by
    # netguard.
    network_mode: "service:netguard"
    depends_on: [netguard]
```

Trade-offs to understand before adopting it:

- The RFC1918 rules also block `n8n_shared`, so container-to-container traffic
  stops working unless you add explicit `ACCEPT` rules for those peers first
  (ordering matters — `iptables` evaluates top-down).
- Debugging gets harder: `docker compose ps` no longer tells you which service
  holds the port.
- Docker Desktop's internal DNS and the embedded resolver live on the gateway
  path; over-broad rules can break name resolution entirely.

If you do go down this path, add `ACCEPT` rules for the `n8n_shared` subnet and
for the embedded DNS resolver (`127.0.0.11`) **before** the `REJECT` rules.
