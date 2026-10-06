# CCF Helm Chart

This chart (`ccf`) deploys the Continuous Compliance Framework: the API, the UI, and optionally a bundled PostgreSQL,
Dex and pgAdmin. Agents are deployed separately with the [`ccf-agent`](../ccf-agent) chart.

## Installation

The chart never generates or looks up credentials at render time (both break `helm template`, and so Argo CD and
Flux). Every credential needs a source, and a plain `helm install` fails, naming the values to set. See
[Credentials](#credentials).

Production, with Secrets you create (or manage with your secret store):

```bash
kubectl create namespace ccf
openssl genrsa -out jwt.pem 2048
kubectl -n ccf create secret generic ccf-jwt --from-file=private_key.pem=jwt.pem
kubectl -n ccf create secret generic ccf-postgres --from-literal=POSTGRES_PASSWORD="$(openssl rand -hex 24)"
kubectl -n ccf create secret generic ccf-admin --from-literal=password="$(openssl rand -hex 16)"

helm install ccf oci://ghcr.io/compliance-framework/helm-charts/ccf -n ccf \
  --set webBaseUrl=https://ccf.example.com \
  --set api.jwt.source=existingSecret --set api.jwt.existingSecret.name=ccf-jwt \
  --set api.jwt.existingSecret.publicKey= \
  --set database.local.createSecret=false --set database.local.existingSecret=ccf-postgres \
  --set api.user.existingSecret=ccf-admin
```

Development only (credentials derived from a seed, a JWT key generated at every API start):

```bash
helm install ccf oci://ghcr.io/compliance-framework/helm-charts/ccf -n ccf --create-namespace \
  --set devSecrets.seed=my-dev-seed --set api.jwt.source=inMemory
```

The chart creates an initial admin user, `api.user.email` (default `admin@localhost`), with the password from
`api.user.existingSecret`, `api.user.password`, an ExternalSecret or the dev seed. `helm install` prints how to read it.

## Credentials

| Credential | existingSecret | External Secrets Operator | Explicit value | Development fallback |
|------------|----------------|---------------------------|----------------|----------------------|
| JWT signing key | `api.jwt.source: existingSecret`, `api.jwt.existingSecret.name` (key `private_key.pem`; `publicKey: ""` derives the public key) | `api.jwt.source: externalSecret` | none | `api.jwt.source: inMemory` |
| PostgreSQL password (bundled DB) | `database.local.existingSecret` + `createSecret: false` (key `POSTGRES_PASSWORD`) | `database.local.externalSecret.enabled` | `database.local.password` | `devSecrets.seed` |
| Initial admin user password | `api.user.existingSecret` (+ `passwordKey`, default `password`) | `api.user.externalSecret.enabled` | `api.user.password` | `devSecrets.seed` |
| Dex client secret (`dex.enabled`) | `dex.clientSecret.existingSecret` + `createSecret: false` | `dex.clientSecret.externalSecret.enabled` | `dex.clientSecret.value` | `devSecrets.seed` |

- **existingSecret** is the primary path. The Secret must exist before the install.
- **External Secrets Operator.** With `externalSecret`, the chart renders an `ExternalSecret`
  (`external-secrets.io/v1`) per credential, with `refreshPolicy: CreatedOnce`: ESO generates the value once and never
  rotates it (a rotated database password would lock the API out of an initialised database). The Secrets keep the names
  the chart used to create itself (`<fullname>-psql`, `<fullname>-initial-user-password`, `<fullname>-dex`,
  `<fullname>-jwt-private-key`) and are owned by their ExternalSecret.
  - Passwords and the Dex client secret come from the `Password` generator
    (`generators.external-secrets.io/v1alpha1`, `externalSecrets.passwordGenerator`, no symbols by default because the
    Postgres password goes into a connection string).
  - No ESO generator produces an RSA key the API can read: the `SSHKey` generator writes OpenSSH format, and the API
    needs a PKCS#1 or PKCS#8 PEM. The JWT `ExternalSecret` therefore uses ESO's template function `genPrivateKey`,
    which writes a PKCS#1 `RSA PRIVATE KEY`; a `Password` generator is only its data source. The public key is derived
    by the `generate-public-key` init container.
  - Needs ESO 0.17 or later (the `external-secrets.io/v1` API and `refreshPolicy`). `externalSecrets.apiVersion`,
    `generatorApiVersion` and `refreshPolicy` can be changed.
- **Explicit values** are rendered into chart-managed Secrets. They are stable, but the value sits in your Helm values.
- **Development fallback: `devSecrets.seed`.** When set, each password defaults to the first 32 hex characters of
  `sha256("ccf:<purpose>:<seed>")` (purposes `postgres`, `initial-user`, `dex-client`). The value depends only on the
  seed, so it is identical on every render, upgrade and `helm template` run, and the database password never changes
  under an initialised database. It is not secret: anyone who knows the seed (it is in your values) can derive the
  passwords. It is empty by default, and an install never uses it unless you set it. For the JWT key, the development
  option is `api.jwt.source: inMemory`: the API generates a key at every start, so sessions and agent tokens end on
  every restart, and it only works with one API replica.

## Key values

The full list is in [`values.yaml`](./values.yaml), with a comment per value.

| Value | Description | Default |
|-------|-------------|---------|
| `webBaseUrl` | Public URL of the UI; derives the API URL, CORS origin, SSO callback and ingress hosts | `""` |
| `api.image.tag` / `ui.image.tag` | API and UI image tags | see `values.yaml` |
| `api.jwt.source` | Required: `existingSecret`, `externalSecret` or `inMemory` (development) | `""` |
| `devSecrets.seed` | Development only: derive the passwords from this seed | `""` |
| `externalSecrets.*` | External Secrets Operator API versions, refresh policy and Password generator spec | see `values.yaml` |
| `api.authz.driver` | `builtin`, `cedar` or `authzen` | `builtin` |
| `api.authz.roleAssignments` | Role grants rendered into `authz-roles.yaml` | `{agents: agent}` |
| `api.agents.strictDisablePublicEndpoints` | Refuse anonymous agent traffic | `false` |
| `api.agents.*`, `api.worker.enabled`, `api.playback.*`, `api.artifacts.*`, `api.evidence.*` | API tuning; unset values keep the API defaults | unset |
| `api.agentBootstrap.*` | Optional Job that creates agent keys and Secrets | disabled |
| `api.ai.*` | AI suggestions (`provider: anthropic`, `baseUrl`, model, limits) | disabled |
| `<component>.podSecurityContext` / `<component>.securityContext` | Per-workload security contexts (`api`, `ui`, `dex`, `database.local`, `pgadmin4`); empty uses the global ones, then the hardened defaults | `{}` |
| `ui.apiUrl`, `ui.config.*`, `ui.extraConfig` | UI runtime `config.json` | see `values.yaml` |
| `api.extraConfig` | Extra `CCF_*` env vars for the API | `{}` |

## Agents

Agents authenticate to the API with an **agent service account key**: a `client-id` (a UUID) and a `client-secret`. The
secret can only be read when the key is created. Use one key per agent release: the key's `client-id` becomes the
agent's `_agent` evidence label.

### Create keys in the UI

In the UI, open **Admin -> Agents**, create an agent and add a key. Store the key in a Secret for the ccf-agent chart:

```bash
kubectl -n ccf-agents create secret generic ccf-agent-credentials \
  --from-literal=CCF_API_AUTH_CLIENT_ID=<client-id> \
  --from-literal=CCF_API_AUTH_CLIENT_SECRET=<client-secret>
```

The same page has a **Configuration** tab for the agent's remote configuration (agent 0.9.0 and later).

### Or let the chart create them

`api.agentBootstrap` adds a `post-install,post-upgrade` hook Job. For each entry in `agents`, it finds the agent by name
(or creates it), creates a never-expiring key and writes it to a Secret with the keys `CCF_API_AUTH_CLIENT_ID` and
`CCF_API_AUTH_CLIENT_SECRET`:

```yaml
api:
  agentBootstrap:
    enabled: true
    agents:
      - name: ccf-agent
        description: In-cluster agent
        secretName: ccf-agent-credentials
        namespace: ccf-agents   # default: the release namespace; must exist
```

- The Job first checks every configured Secret. When all exist it logs that and exits: a re-run on upgrade never calls
  the API or reads the admin password, so it keeps working after you change the initial password. Delete a Secret
  (and revoke its old key in the UI) to issue a new key.
- When a Secret is missing, the Job logs in as the chart's initial user by default (the password from the initial
  user's source; `adminCredentials` overrides it). Under the `cedar` driver that user needs the `admin` role in
  `api.authz.roleAssignments.users`.
- The Secrets are not part of the release, so `helm uninstall` keeps them.
- The Job has a ServiceAccount and, in each target namespace, a Role allowing `get` on the listed Secrets and `create`
  on Secrets. All are hook resources, deleted when the Job succeeds.
- The Job runs on the official curl image (`curlimages/curl:8.22.0`) as its non-root user (uid 100, gid 101), with a
  read-only root filesystem and an `emptyDir` at `/tmp`. It installs nothing at runtime, so it needs no package
  mirror. A custom `api.agentBootstrap.image` needs a POSIX shell, curl 8.3 or later and busybox-style `grep`,
  `sed`, `tr`, `head` and `mktemp`; update `api.agentBootstrap.podSecurityContext` to match its user.
- Agent names may contain letters, digits, spaces, `.`, `_` and `-`. The Job finds an existing agent by its exact
  name before creating one, so it never adds a second agent with the same name. If several agents already share the
  name, the Job fails and asks you to rename or remove the duplicates in Admin -> Agents.
- Helm waits for the hook up to `--timeout` (default 5m). Raise it together with `api.agentBootstrap.waitSeconds` if
  the API takes longer to become ready.

Then install the agent:

```bash
helm install ccf-agent oci://ghcr.io/compliance-framework/helm-charts/ccf-agent -n ccf-agents \
  --set agent.api.url=http://ccf-api.ccf.svc:8080 \
  --set agent.api.auth.enabled=true \
  --set agent.api.auth.existingSecret=ccf-agent-credentials
```

## Authorization

`api.authz.driver` selects the policy engine:

- `builtin` (default): password users are super admins; SSO users need the admin groups for admin and agent
  resources. Agent service accounts may only register, ingest and sync.
- `cedar`: an embedded Cedar RBAC engine. **Deny by default**: set up `roleAssignments` before switching.
- `authzen`: a remote AuthZEN PDP at `api.authz.authzen.endpoint` (required), with an optional decision cache
  (`cacheTtl`). `failMode` decides what happens when the PDP is unreachable. The readiness probe includes the PDP
  health, so a PDP outage makes the API pods unready.

`api.authz.roleAssignments` is rendered into `authz-roles.yaml`, which the API reconciles into its role-assignment
table at every migration and start, for every driver (so the grants also show in the admin UI). Removing an entry
removes that grant. A change rolls the API pods.

- Roles: `admin`, `contributor`, `auditor`, `viewer`, `agent`, `ssp-subscriber`.
- `users:` grants by login email. `groups:` grants by group name, which under cedar applies to native CCF groups and
  to SSO groups mapped through the provider's `group_mapping`. `agents:` is the role of every authenticated agent.
- `anonymous:` has no default; empty means deny. Under cedar, while public agent endpoints are allowed (the default),
  the API grants anonymous requests the `agent` role unless `anonymous:` is set.

Operator Cedar policies can be added with `api.authz.cedar.policies` (a map of `*.cedar` files) or
`api.authz.cedar.existingConfigMap`, mounted at `api.authz.cedar.policyDir` (default `/etc/ccf/cedar-policies`).

## Security notes

- **Strict mode.** With `api.agents.strictDisablePublicEndpoints: false` (the default), anonymous callers can send
  heartbeats and evidence, upload artifacts and run Rego playback, and under cedar they get the `agent` role. Set it to
  `true` once every agent has a key.
- **Playback.** `/api/playback` runs caller-supplied Rego in the API process. It is open to anonymous callers while
  strict mode is off. Disable it with `api.playback.enabled: false` if you do not need it.
- **Workload hardening.** Every workload runs as a non-root user with a read-only root filesystem, no privilege
  escalation, all capabilities dropped and the `RuntimeDefault` seccomp profile, with an `emptyDir` for every path it
  writes. Each one takes its own `podSecurityContext` / `securityContext`, then the global ones, then these defaults:

  | Workload | User | Writable paths (emptyDir unless noted) | Notes |
  |----------|------|----------------------------------------|-------|
  | API pod | 65532 (all containers) | `/tmp`, the `publickey` volume | `generate-public-key` uses `alpine/openssl:3.5.9`, nothing installed at runtime |
  | UI (nginx) | 101 | `/var/cache/nginx`, `/run`, `/tmp` | the pod sets the safe sysctl `net.ipv4.ip_unprivileged_port_start=0` so nginx keeps port 80 |
  | Dex | 1001 | `/tmp` | |
  | PostgreSQL | 999 | data volume, `/var/run/postgresql`, `/tmp` | see below |
  | pgAdmin 4 | 5050 | `/var/lib/pgadmin`, `/run/pgadmin`, `/tmp` | listens on 8080; its `config_distro.py` lives in `/var/lib/pgadmin` |
  | Agent bootstrap Job | 100 | `/tmp` | `curlimages/curl` |

  Not fully hardened:
  - **PostgreSQL volume permissions.** Postgres refuses a data directory it does not own, and volumes without
    `fsGroup` support (such as the chart's default `hostPath` PV) start root-owned. The `volume-permissions` init
    container chowns the volume root to 999 as root, with only the `CHOWN` and `FOWNER` capabilities and a read-only
    root filesystem. Disable it (`database.local.volumePermissions.enabled: false`) when the volume root is already
    owned by 999 (for example a volume an earlier release initialised): the pod then meets the Pod Security
    `restricted` profile.
  - The UI pod's sysctl needs a cluster that allows safe sysctls (the default). Otherwise set `ui.podSecurityContext`
    without it and serve the UI on a port above 1023 with your own nginx configuration.
  - The `helm test` pod (`templates/tests`) is unchanged.
- **JWT key.** The chart no longer generates the key. Use an existing Secret, External Secrets Operator, or
  `inMemory` for development. All three are stable under `helm template` (Argo CD, Flux).

## Request sizes

Whatever ingress, gateway or proxy fronts the API must accept the request sizes agents send:

- policy-evaluation artifacts: up to 16 MiB each (`api.artifacts.maxBytes`);
- agent configuration reports: up to 4 MiB;
- Rego playback requests: up to 2 MiB (`api.playback.maxBytes`).

Many ingress controllers default to a smaller body limit (1 MiB is common). Raise it in your ingress or gateway
configuration (for example with `api.ingress.annotations`); the chart sets no controller-specific defaults. Agents that
call the API Service directly inside the cluster are not affected.

## Database growth

Agents upload policy-evaluation artifacts (the policy bundle, input and data of each evaluation), which the API stores
in PostgreSQL, deduplicated by digest. There is no retention for them yet, so the database grows with the number of
distinct evaluations. Size `database.local.persistence.size` (default `10Gi`) or your external database accordingly.

## AI suggestions

`api.ai` enables AI suggestions. The only provider is `anthropic`; `baseUrl` points the client at a proxy. The chart
defaults `model` to `claude-haiku-4-5`, while the API's own default is `claude-opus-4-8`.

## Upgrading

### 0.8.x to 0.9.0 (API 0.17.1 to 0.21.0, UI 2.10.1 to 2.12.1)

1. **Back up the database.** `migrate-db` adds the tables of API 0.18 to 0.21 (control links and lineage, SSP export
   offerings, policy-evaluation artifacts, agent configuration revisions and instances, evidence subjects). No manual
   steps are needed.
2. **Authorization.**
   - `authz-roles.yaml` is now mounted in every case and in `migrate-db`. Before, with `api.jwt.source: inMemory` and
     no SSO, email, Slack, workflow or Dex config, it was never mounted, and each rollout removed the config-owned
     grants until the API restarted.
   - Under `builtin`, every action on agents needs the admin check for users; agent service accounts may only
     register, ingest and sync.
   - Under `cedar`, the `agent` role gains sync, artifact read/ingest and playback; a new `ssp-subscriber` role exists.
3. **The API pods roll on config changes** (checksum annotations), and on this upgrade.
4. **Credentials (breaking).** The chart no longer generates or looks up the JWT key, the Postgres password, the
   initial user's password or the Dex client secret: `lookup` returns nothing under `helm template`, so with Argo CD
   these changed on every sync. Rendering fails until each has a source (see Credentials). To keep the values your
   install already uses, copy the generated Secrets to new names and point the chart at the copies **before**
   upgrading (Helm deletes the old chart-managed Secrets during the upgrade):

   ```bash
   NS=ccf; R=ccf   # namespace and <fullname> of the release
   copy() { kubectl -n "$NS" get secret "$1" -o json \
     | jq --arg n "$2" '{apiVersion, kind, type, data, metadata: {name: $n}}' | kubectl -n "$NS" apply -f -; }
   copy "$R-jwt-private-key" ccf-jwt
   copy "$R-psql" ccf-postgres
   copy "$R-initial-user-password" ccf-admin
   copy "$R-dex" ccf-dex   # only with dex.enabled
   ```

   ```yaml
   api:
     jwt:
       source: existingSecret
       existingSecret:
         name: ccf-jwt
         publicKey: ""          # the old Secret holds only private_key.pem; the init container derives the public key
     user:
       existingSecret: ccf-admin
   database:
     local:
       createSecret: false
       existingSecret: ccf-postgres
   dex:
     clientSecret:
       createSecret: false
       existingSecret: ccf-dex
   ```

   `api.jwt.source: generated` was removed and now fails with this explanation. An install that set
   `database.local.existingSecret` while keeping `createSecret: true` must now set `createSecret: false`.
5. **Every workload is hardened** (non-root, read-only root filesystem; see Security notes). Installs that set a
   component's or the global `podSecurityContext` / `securityContext` keep what they set. `pgadmin4.containerPort`
   defaults to `8080` (the Service still targets it by name). The `generate-public-key` init container uses
   `alpine/openssl:3.5.9` with `openssl` as its command: if you overrode its image or command for the old
   `apk add` flow, update them or give it a `securityContext` that allows that flow. A PostgreSQL volume
   initialised by an earlier release is already owned by uid 999.
6. **Probes** now use `GET /api/health` (liveness) and `GET /api/health/ready` (readiness).
7. **`APP_PORT` is replaced by `CCF_APP_PORT`**, taken from `api.containerPort`.
8. **The UI container no longer gets an `API_URL` env var**; it never had an effect. Use `ui.apiUrl` or `webBaseUrl`.
9. **New API settings are optional.** Unset, the API defaults apply: playback on, artifacts 16 MiB / 8 concurrent,
   agent instances stale after 10m and pruned after 720h (24h for one-shot), 500 instances per agent, evidence
   subjects `off`, strict mode off.
10. **Agents.** Upgrade this chart before ccf-agent 0.4.0 (agent 0.9.0), then give each agent a key (see Agents).
