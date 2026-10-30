# REST API and webhooks

Everything is served from the single loopback port `127.0.0.1:5678`.

| Path            | What it is |
|-----------------|------------|
| `/`             | Editor UI |
| `/healthz`      | Liveness probe, no auth, used by the container healthcheck |
| `/api/v1/...`   | Public REST API — manage workflows, executions, credentials, tags |
| `/webhook/...`  | **Production** webhook endpoints (active workflows only) |
| `/webhook-test/...` | **Test** webhook endpoints (one request, editor must be listening) |
| `/rest/...`     | Internal UI API. Undocumented, unstable, cookie-authenticated. Do not build against it. |

## Health check

```bash
curl -s http://127.0.0.1:5678/healthz
# {"status":"ok"}
```

## REST API

`N8N_PUBLIC_API_DISABLED=false` is already set in `docker-compose.yml`, so the
API is live. It authenticates with an API key, not with your login session.

### Creating an API key

1. Open http://127.0.0.1:5678
2. **Settings → n8n API → Create an API key**
3. Copy it immediately — it is shown once.

```bash
export N8N_API_KEY='paste-the-key-here'
export N8N_URL='http://127.0.0.1:5678'
```

### Calling it

The header is `X-N8N-API-KEY`.

```bash
# List workflows
curl -s "$N8N_URL/api/v1/workflows" \
  -H "X-N8N-API-KEY: $N8N_API_KEY" | python3 -m json.tool

# One workflow
curl -s "$N8N_URL/api/v1/workflows/<id>" \
  -H "X-N8N-API-KEY: $N8N_API_KEY"

# Recent executions
curl -s "$N8N_URL/api/v1/executions?limit=10" \
  -H "X-N8N-API-KEY: $N8N_API_KEY"

# Import a workflow from a file
curl -s -X POST "$N8N_URL/api/v1/workflows" \
  -H "X-N8N-API-KEY: $N8N_API_KEY" \
  -H 'Content-Type: application/json' \
  --data-binary @examples/workflows/hello-webhook.json

# Activate / deactivate
curl -s -X POST "$N8N_URL/api/v1/workflows/<id>/activate"   -H "X-N8N-API-KEY: $N8N_API_KEY"
curl -s -X POST "$N8N_URL/api/v1/workflows/<id>/deactivate" -H "X-N8N-API-KEY: $N8N_API_KEY"
```

Interactive API docs are served by your own instance at
http://127.0.0.1:5678/api/v1/docs — they match the exact version you are
running, which the public documentation may not.

### Note on triggering runs

The public API intentionally has **no "execute this workflow now" endpoint**.
To trigger a workflow from outside, give it a Webhook trigger and call the
webhook URL. That is the supported mechanism.

## Webhooks

Two URL families, and the difference trips everyone up once:

| | Test | Production |
|---|---|---|
| URL | `/webhook-test/<path>` | `/webhook/<path>` |
| Requires | editor open, **Execute workflow** clicked | workflow **Active** |
| Lifetime | one request, then it stops listening | permanent |
| Shows data in the editor | yes | no (see Executions) |

### Example

Import `examples/workflows/hello-webhook.json`, then:

```bash
# Test mode: click "Execute workflow" in the editor first
curl -X POST http://127.0.0.1:5678/webhook-test/hello \
  -H 'Content-Type: application/json' \
  -d '{"hello":"world"}'

# Production mode: toggle the workflow to Active first
curl -X POST http://127.0.0.1:5678/webhook/hello \
  -H 'Content-Type: application/json' \
  -d '{"hello":"world"}'
```

The response contains the path of the file the workflow wrote. Confirm it
landed on the host:

```bash
ls -l "$HOME/docker/n8n_data/files/"
```

### Responses

The Webhook node's **Respond** setting decides what the caller gets:

- `Immediately` — `200 {"message":"Workflow was started"}`, workflow runs async.
- `When Last Node Finishes` — the last node's output is returned.
- `Using 'Respond to Webhook' Node` — you control status, headers and body
  explicitly. The example workflow uses this.

### Calling webhooks from other containers

From a container on `n8n_shared`, do **not** use `127.0.0.1` — that is the
calling container's own loopback. Use the service name:

```bash
curl -X POST http://n8n:5678/webhook/hello -d '{"from":"sidecar"}'
```

### Exposing webhooks to the internet

The port is bound to loopback, so external services (GitHub, Stripe, …) cannot
reach it. For a temporary public URL, run a tunnel on the **host**:

```bash
cloudflared tunnel --url http://127.0.0.1:5678
```

Then set `WEBHOOK_URL=https://<your-tunnel-host>/` in `.env` and run
`./n8n.sh restart`, so n8n advertises the public URL in the editor.

Treat any such tunnel as a temporary, fully public entry point into your n8n
instance. Shut it down when you are done.
