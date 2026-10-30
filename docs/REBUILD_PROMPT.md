# Prompt pro znovuvytvoření tohoto repozitáře

Tento soubor je **samostatný prompt**. Zkopíruj všechno od značky
`=== ZAČÁTEK PROMPTU ===` níž a vlož to do AI asistenta (Claude, ChatGPT,
Copilot, Cursor…). Výsledkem bude funkční kopie tohoto repozitáře.

Prompt je psán česky, ale **všechny vygenerované soubory musí být anglicky**.

---

=== ZAČÁTEK PROMPTU ===

Vytvoř repozitář `n8nDemo` — reprodukovatelný sandbox pro n8n Community
Edition běžící v Dockeru. Cílem je, aby šlo repozitář kdykoliv naklonovat na
jakýkoliv macOS nebo Linux stroj, spustit jeden skript a mít funkční n8n —
a stejně tak ho beze stop zase odstranit.

## Jazyk

Veškerý obsah souborů (kód, komentáře, README, dokumentace, commit messages)
piš **anglicky**. Jedinou výjimkou je soubor `docs/REBUILD_PROMPT.md`, který je
česky a obsahuje tento prompt.

## Cílové prostředí

- macOS (Apple Silicon i Intel) a Linux x86_64
- Docker Engine + plugin **Compose v2** (`docker compose`, ne `docker-compose`)
- Shell skripty v `bash`, přenositelné mezi macOS (BSD utils) a Linuxem (GNU
  utils) — pozor na rozdíly v `sed -i`, `stat`, `readlink -f`

## Architektura, kterou implementuj

### Kontejner

Jeden kontejner s n8n Community Edition:

- image `docker.n8n.io/n8nio/n8n:${N8N_VERSION}`, verzi **připni** (v době
  psaní `1.123.91`), nikdy `latest`
- úložiště **SQLite** (výchozí n8n), žádný Postgres
- port publikovaný **pouze na loopback**: `127.0.0.1:${N8N_PORT}:5678`
- healthcheck na `/healthz` pomocí `wget` (image je Alpine/BusyBox, `curl`
  nemusí být přítomen)

Povinné proměnné prostředí:

| Proměnná | Hodnota | Proč |
|---|---|---|
| `N8N_HOST` | `localhost` | |
| `N8N_PORT` | `5678` | interní port |
| `N8N_PROTOCOL` | `http` | |
| `WEBHOOK_URL` | `http://localhost:${N8N_PORT}/` | základ URL produkčních webhooků |
| `N8N_SECURE_COOKIE` | `false` | n8n jinak odmítne nastavit auth cookie přes plain HTTP |
| `DB_TYPE` | `sqlite` | |
| `N8N_ENCRYPTION_KEY` | z `.env` | šifrování credentials |
| `GENERIC_TIMEZONE`, `TZ` | `Europe/Prague` | |
| `N8N_PUBLIC_API_DISABLED` | `false` | zapne REST API na `/api/v1` |
| `N8N_RUNNERS_ENABLED` | `true` | podporovaný model spouštění Code nodes |
| `NODE_FUNCTION_ALLOW_BUILTIN` | `*` | |
| `NODE_FUNCTION_ALLOW_EXTERNAL` | `*` | |
| `N8N_BLOCK_ENV_ACCESS_IN_NODE` | `true` | Code node nesmí přečíst env, tedy ani encryption key |
| `N8N_DIAGNOSTICS_ENABLED` | `false` | |
| `N8N_VERSION_NOTIFICATIONS_ENABLED` | `false` | |
| `N8N_HIRING_BANNER_ENABLED` | `false` | |

Bezpečnostní nastavení, která nic neomezují v experimentování:

- `security_opt: [no-new-privileges:true]`
- `cap_drop: [ALL]`
- **nikdy** nemountuj `/var/run/docker.sock` (= root na hostu)
- `extra_hosts: ["host.docker.internal:host-gateway"]` — host **má** být
  dostupný, je to záměr; na Linuxu je tento řádek nutný

### Úložiště na hostu

Interface adresář `$HOME/docker/n8n_data`, rozdělený na dva podadresáře, aby se
interní stav n8n nemíchal s uživatelskými soubory:

| Host | Kontejner | Obsah |
|---|---|---|
| `$HOME/docker/n8n_data/.n8n` | `/home/node/.n8n` | SQLite DB, encryption key, logy |
| `$HOME/docker/n8n_data/files` | `/data/files` | výměna souborů host ↔ workflow |

### Sítě

| Síť | Typ | Účel |
|---|---|---|
| `n8n_net` | spravovaná Composem, bridge | výchozí egress, NAT na internet |
| `n8n_shared` | **`external: true`**, vytváří ji `bootstrap.sh` | komunikace mezi kontejnery napříč stacky |

`n8n_shared` musí být externí, aby `./n8n.sh destroy` nemohl síť odstranit
zpod cizích stacků, které na ní visí.

### Izolace — záměrné rozhodnutí

Žádná omezení egressu. n8n smí na internet, na LAN i na hostitelské služby
přes `host.docker.internal`. Je to sandbox pro zkoušení.

Hranice, které platí tak jako tak, a které v dokumentaci **jasně popiš**:

- souborový systém hosta **není** vidět, kromě dvou bind mountů výše
- Docker daemon **není** dostupný, protože socket není namountovaný

Do `docs/NETWORKING.md` navíc popiš volitelný recept na skutečnou izolaci
pomocí **network sidecaru** (kontejner s `NET_ADMIN`, který vlastní network
namespace a aplikuje iptables; n8n se připojí přes `network_mode:
service:<sidecar>`). Uveď i jeho nevýhody: RFC1918 pravidla rozbijí
container-to-container provoz, pokud se před REJECT nedají ACCEPT pravidla pro
`n8n_shared` a pro embedded DNS `127.0.0.11`.

## Soubory k vytvoření

```
n8nDemo/
├── README.md
├── .gitignore
├── .env.example
├── docker-compose.yml
├── bootstrap.sh                  (spustitelný)
├── n8n.sh                        (spustitelný)
├── scripts/
│   ├── lib.sh
│   └── github-init.sh            (spustitelný)
├── docs/
│   ├── NETWORKING.md
│   ├── API.md
│   └── REBUILD_PROMPT.md
└── examples/
    ├── sidecar-service/docker-compose.yml
    └── workflows/hello-webhook.json
```

### `.gitignore`

Ignoruj `.env`, `backups/`, `.DS_Store`, editorové adresáře.

### `.env.example`

Komentovaná šablona s `N8N_VERSION`, `N8N_PORT`, `N8N_DATA_DIR`,
`N8N_ENCRYPTION_KEY`, `GENERIC_TIMEZONE`. Placeholdery pro cestu a klíč, které
`bootstrap.sh` nahradí. U encryption key uveď varování, že bez něj nejdou
obnovit credentials.

### `scripts/lib.sh`

Sdílené funkce, soubor se jen sourcuje:

- barevné `log`/`ok`/`warn`/`die`, barvy vypnuté pokud stdout není terminál
- `detect_os` → `macos` | `linux`, jinak `die`
- `require_cmd <cmd> [hint]`
- `require_docker` — ověří CLI, plugin Compose v2 i dostupnost démona
- `env_get <file> <key>` — přečte jeden klíč z env souboru **bez** sourcování
- `confirm_word <word> <prompt>` — potvrzení opsáním přesného slova

### `bootstrap.sh`

Idempotentní, `set -euo pipefail`. Nikdy nepřepisuje existující `.env` a nikdy
nesahá na existující data.

1. **Preflight**: `require_docker`, `require_cmd openssl`
2. **Adresáře**: cílovou cestu vezmi z existujícího `.env`, pokud existuje
   (aby re-run nepřestěhoval data), jinak `$HOME/docker/n8n_data`. Vytvoř
   `.n8n/` a `files/`. **Na Linuxu** `chown 1000:1000` (uživatel `node`
   v image), s fallbackem na `sudo` a srozumitelnou chybou. Na macOS to Docker
   Desktop řeší sám — nedělej to tam.
3. **`.env`**: vygeneruj ze šablony pomocí `sed` s oddělovačem `|` (cesta
   obsahuje `/`), doplň absolutní `N8N_DATA_DIR` a
   `N8N_ENCRYPTION_KEY=$(openssl rand -hex 32)`, nastav `chmod 600`, vypiš
   varování o záloze klíče.
4. **Kontrola portu**: pokud už neběží náš vlastní kontejner `n8n` a port je
   obsazený (`lsof`), skonči s radou změnit `N8N_PORT`.
5. **Síť**: `docker network create n8n_shared`, pokud neexistuje.
6. **Start**: `docker compose up -d`, pak aktivně čekej na stav `healthy`
   přes `docker inspect -f '{{.State.Health.Status}}'`, timeout 180 s. Při
   `unhealthy` nebo timeoutu vypiš posledních 40 řádků logu a skonči chybou.
7. Závěrečný výpis: URL, cesty na hostu, odkaz na `./n8n.sh`.

### `n8n.sh`

Jeden ovládací skript s příkazy:

| Příkaz | Chování |
|---|---|
| `up` | zajistí existenci `n8n_shared`, `docker compose up -d` |
| `down` | `docker compose down`, data zůstávají |
| `restart` | `docker compose up -d --force-recreate` |
| `status` | `compose ps`, health, připojené sítě s IP, `du -sh` datového adresáře |
| `logs [-f]` | posledních 200 řádků, nebo follow |
| `shell` | `docker exec -it n8n /bin/sh` |
| `url` | vypíše `http://127.0.0.1:<port>` |
| `backup` | **zastaví kontejner** (konzistentní SQLite snapshot), `tar -czf` datového adresáře do `./backups/n8n-data-<timestamp>.tar.gz`, znovu nastartuje jen pokud běžel; upozorní, že archiv je **tajemství** — viz níže |
| `restore <file>` | potvrzení slovem `RESTORE`, `compose down`, smaže datový adresář, rozbalí archiv, na Linuxu chown, porovná klíče (viz níže), `up` |
| `destroy [--purge-data]` | potvrzení `DESTROY` → `compose down --volumes --remove-orphans`, smaže image; `n8n_shared` smaže **jen pokud na ní nevisí žádný kontejner**. S `--purge-data` navíc druhé potvrzení `DELETE-DATA` a smazání datového adresáře i `.env` |
| `help` | nápověda |

Každý příkaz pracující s daty musí nejdřív ověřit, že `.env` existuje, a jinak
odkázat na `./bootstrap.sh`.

**Důležitý fakt o encryption key, nepřehlédni:** n8n si encryption key zapisuje
do `.n8n/config` jako **plaintext JSON**. Záložní archiv ho tedy obsahuje —
spolu se zašifrovanými credentials v `database.sqlite`. Nepiš nikam, že „klíč
v archivu není“; to je nepravda. Místo toho:

- v `backup` varuj, že archiv je tajemství a patří do `backups/`, který je
  v `.gitignore`
- v `restore` po rozbalení **porovnej** klíč z `.n8n/config` s hodnotou
  `N8N_ENCRYPTION_KEY` v `.env`; při neshodě vypiš klíč z archivu a instrukci,
  že ho má uživatel vložit do `.env` a spustit `./n8n.sh restart`. Env proměnná
  má u n8n přednost před souborem, takže neshoda znamená nerozšifrovatelné
  credentials.

### `scripts/github-init.sh`

Publikace na GitHub, parametry `[owner] [repo-name]`, výchozí `dflegl n8nDemo`,
viditelnost **public**.

- nastaví `git config user.name/user.email` **lokálně v repu** (bez
  `--global`), aby zůstala nedotčená firemní identita
- ověří `gh auth status`; pokud cílový účet chybí, **neskončí tiše** — vypíše
  instrukci `gh auth login --hostname github.com --web`, seznam známých účtů
  a skončí chybou
- `gh auth switch --hostname github.com --user <owner>`, pokud aktivní účet
  není ten cílový
- vytvoří initial commit, pokud repo žádný nemá; pokud existují necommitnuté
  změny, odmítne pokračovat
- `gh repo create <owner>/<name> --public --source=. --remote=origin --push`,
  nebo prostý `git push`, pokud `origin` už existuje

### `examples/sidecar-service/docker-compose.yml`

Dva kontejnery bez mapovaných portů, připojené na externí `n8n_shared`:
`traefik/whoami:v1.10` a `kennethreitz/httpbin:latest`. V komentáři vysvětli,
že n8n je volá jménem služby (`http://whoami/`), ne přes localhost.

### `examples/workflows/hello-webhook.json`

Importovatelný n8n workflow, validní JSON:

1. `n8n-nodes-base.webhook` (typeVersion 2) — POST, path `hello`,
   `responseMode: responseNode`
2. `n8n-nodes-base.code` (typeVersion 2) — zabalí `$input.first().json.body`
   spolu s ISO timestampem a vygenerovaným názvem souboru
3. `n8n-nodes-base.convertToFile` (typeVersion 1.1) — operace `toJson`
4. `n8n-nodes-base.readWriteFile` (typeVersion 1) — operace `write`, cílová
   cesta `/data/files/{{ ... }}`
5. `n8n-nodes-base.respondToWebhook` (typeVersion 1.1) — vrátí JSON s cestou
6. `n8n-nodes-base.stickyNote` — vysvětlivka přímo v plátně

Nezapomeň na `connections`, `settings.executionOrder: "v1"` a unikátní `id`
u každé node.

### `docs/API.md`

- tabulka endpointů: `/`, `/healthz`, `/api/v1/...`, `/webhook/...`,
  `/webhook-test/...`, a poznámka že `/rest/...` je interní a nestabilní
- jak vytvořit API key (Settings → n8n API), hlavička `X-N8N-API-KEY`
- `curl` příklady: list workflows, detail, executions, import workflow z
  souboru, activate/deactivate
- upozornění, že REST API **nemá** endpoint pro spuštění workflow — od toho
  jsou webhooky
- rozdíl `/webhook-test/` (editor otevřený, jeden request) vs `/webhook/`
  (workflow aktivní, trvalý), v tabulce
- volání webhooku z jiného kontejneru: `http://n8n:5678/...`, **ne**
  `127.0.0.1`
- volitelné vystavení ven přes `cloudflared tunnel --url http://127.0.0.1:5678`
  a nutnost upravit `WEBHOOK_URL` + `./n8n.sh restart`

### `docs/NETWORKING.md`

- ASCII diagram topologie
- tabulka obou sítí
- co n8n **může**: internet, jiné kontejnery přes DNS jméno, host přes
  `host.docker.internal` (na Docker Desktop macOS i služby bindnuté na
  `127.0.0.1`), celá LAN
- co n8n **nemůže**: filesystem hosta kromě dvou mountů, Docker daemon
- tabulka už aplikovaného hardeningu a jeho efektu
- sekce o praktickém riziku: n8n templates z internetu běží s těmito právy
- volitelný recept na iptables sidecar včetně nevýhod

### `README.md`

Přesně čtyři hlavní sekce, v tomto pořadí:

1. **Purpose** — k čemu repo je, co dává, explicitní vymezení rozsahu (není to
   produkce), licenční poznámka o Sustainable Use License (n8n **není**
   OSI open source)
2. **Deployment** — tabulka prerekvizit, `git clone` + `./bootstrap.sh`, popis
   co bootstrap dělá, první přihlášení, **samostatná a výrazná pasáž o záloze
   `N8N_ENCRYPTION_KEY`**, publikace na GitHub (přes skript i ručně)
3. **Usage** — přehled příkazů `./n8n.sh`, výměna souborů s tabulkou mountů,
   REST API a webhooky s odkazem na `docs/API.md`, import ukázkového workflow,
   připojení jiného kontejneru s copy-paste YAML snippetem, přístup na host
   **včetně blockquote s bezpečnostním upozorněním**, upgrade verze, backup
   a restore
4. **Teardown & cleanup** — tabulka **všech artefaktů, které projekt na hostu
   vytvoří** (kontejner, image, dvě sítě, datový adresář, `.env`, `backups/`,
   ukázkové kontejnery) s uvedením, co je odstraní; rozdíl mezi `down` (pauza)
   a `destroy --purge-data` (smazání); manuální fallback příkazy; příkazy
   k ověření, že nic nezbylo

Na konci přidej strom repozitáře s krátkým popisem souborů.

## Kontrola na závěr

Po vytvoření ověř:

1. `bash -n` projde na všech `.sh` souborech
2. `docker compose config` projde (s dočasným `.env`)
3. `examples/workflows/hello-webhook.json` je validní JSON
4. `./bootstrap.sh` doběhne do stavu healthy
5. `curl -s http://127.0.0.1:5678/healthz` vrátí `{"status":"ok"}`
6. po `cd examples/sidecar-service && docker compose up -d` projde z kontejneru
   n8n příkaz `wget -qO- http://whoami/`
7. `./n8n.sh backup` vytvoří archiv a kontejner nechá běžet
8. `./n8n.sh status` vypíše obě sítě

=== KONEC PROMPTU ===

---

## Poznámky k údržbě

Když tohle repo změníš, aktualizuj i prompt výše. Prompt je specifikace —
pokud se rozejde s realitou, přestane být k čemu.

Co se nejspíš bude měnit:

- **`N8N_VERSION`** — ověř aktuální stabilní tag na
  [Docker Hub](https://hub.docker.com/r/n8nio/n8n/tags). Pozor, n8n publikuje
  více tag sérií; `stable` a `latest` v době psaní ukazovaly na `1.123.91`.
- **`typeVersion` u nodes** v ukázkovém workflow — po větším upgrade n8n ověř,
  že import nehlásí varování.
- **Názvy env proměnných** — n8n je občas přejmenovává a stará jména deprekuje.
  Při upgradu zkontroluj `./n8n.sh logs` na deprecation warnings.
