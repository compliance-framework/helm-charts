# CCF Helm Chart

This chart (`ccf`) deploys the Continuous Compliance Framework: the API, the UI, and optionally a bundled PostgreSQL,
Dex and pgAdmin. Agents are deployed separately with the [`ccf-agent`](../ccf-agent) chart.

## Installation

A plain `helm install` works as before 0.9.0: the chart generates the credentials itself (`lookup` of the existing
Secrets, else random values; a new JWT key on every render). That path is **deprecated and not GitOps-safe**, and NOTES
print a DEPRECATED notice for it. Production installs should give every credential an explicit source; see
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
`api.user.existingSecret`, `api.user.password`, an ExternalSecret, the dev seed or, by default, the deprecated generated
`<fullname>-initial-user-password` Secret. `helm install` prints how to read it.

## Credentials

Sources, highest first (the first one set wins):

| Credential | existingSecret | External Secrets Operator | Explicit value | Development fallback | **Default: deprecated generated** |
|------------|----------------|---------------------------|----------------|----------------------|------------------------------------|
| JWT signing key | `api.jwt.source: existingSecret`, `api.jwt.existingSecret.name` (key `private_key.pem`; `publicKey: ""` derives the public key) | `api.jwt.source: externalSecret` | none | `api.jwt.source: inMemory` | `api.jwt.source: generated` (the default): a new key on every render, no lookup |
| PostgreSQL password (bundled DB) | `database.local.existingSecret` + `createSecret: false` (key `POSTGRES_PASSWORD`) | `database.local.externalSecret.enabled` | `database.local.password` | `devSecrets.seed` | `createSecret: true` (the default): `lookup` of `<fullname>-psql`, else random |
| Initial admin user password | `api.user.existingSecret` (+ `passwordKey`, default `password`) | `api.user.externalSecret.enabled` | `api.user.password` | `devSecrets.seed` | `lookup` of `<fullname>-initial-user-password`, else random |
| Dex client secret (`dex.enabled`) | `dex.clientSecret.existingSecret` + `createSecret: false` | `dex.clientSecret.externalSecret.enabled` | `dex.clientSecret.value` | `devSecrets.seed` | `createSecret: true` (the default): `lookup` of `<fullname>-dex`, else random |

Rendering fails only when generation is turned off without another source: `createSecret: false` without
`existingSecret` or `externalSecret`, or an empty `api.jwt.source`. The message lists the options.

- **Deprecated generated (the default).** The chart's behaviour before 0.9.0, kept so existing installs and plain
  installs keep working: passwords come from `lookup` of the existing Secret, else a random value, and the JWT key is a
  new random key on every render. **It is not GitOps-safe.** Under Argo CD or `helm template`, `lookup` returns
  nothing, so the passwords are regenerated on every sync, and the API can no longer connect to an already-initialised
  PostgreSQL. The JWT key rotates on every `helm upgrade` and every sync, logging every user out and invalidating every
  agent token. NOTES print one DEPRECATED notice listing the credentials on this path. It will be removed in a future
  release: move to `existingSecret` (the copy recipe in the upgrade notes keeps the current values) or, for fresh
  installs only, `externalSecret`.
- **existingSecret** is the recommended path. The Secret must exist before the install.
- **External Secrets Operator generation is for fresh installs.** The generated Secrets take the names the chart used to
  create itself, so switching an existing install to ESO replaces its values: Helm deletes the chart-managed Secrets
  and ESO generates new ones, so the Postgres password no longer matches the initialised database (an outage), the
  admin's real password no longer matches its Secret (the bootstrap Job login fails), and the JWT key rotates (everyone
  is logged out). Existing installs keep their values with the copy-to-existingSecret recipe in the upgrade notes, or
  must rotate the Postgres password themselves before switching.
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
    `generatorApiVersion` and `refreshPolicy` can be changed. CI installs ESO 2.11.0 and checks the whole path: every
    ExternalSecret becomes Ready, the API starts with the generated JWT key and Postgres password, the bootstrap Job
    logs in with the generated admin password, and a forced ESO sync leaves the Secret data unchanged.
- **Explicit values** are rendered into chart-managed Secrets. They are stable, but the value sits in your Helm values.
- **Development fallback: `devSecrets.seed`.** When set, each password defaults to the first 32 hex characters of
  `sha256("ccf:<purpose>:<seed>")` (purposes `postgres`, `initial-user`, `dex-client`). The value depends only on the
  seed, so it is identical on every render, upgrade and `helm template` run, and the database password never changes
  under an initialised database. It is not secret: anyone who knows the seed (it is in your values) can derive the
  passwords. It is empty by default, and an install never uses it unless you set it. It wins over the deprecated
  generated default. For the JWT key, the development
  option is `api.jwt.source: inMemory`: the API generates a key at every start, so sessions and agent tokens end on
  every restart, and it only works with one API replica.

## Key values

The full list is in [`values.yaml`](./values.yaml), with a comment per value.

| Value | Description | Default |
|-------|-------------|---------|
| `webBaseUrl` | Public URL of the UI; derives the API URL, CORS origin, SSO callback and ingress hosts | `""` |
| `api.image.tag` / `ui.image.tag` | API and UI image tags | see `values.yaml` |
| `api.jwt.source` | `existingSecret`, `externalSecret`, `inMemory` (development) or the deprecated `generated` | `generated` (deprecated) |
| `devSecrets.seed` | Development only: derive the passwords from this seed | `""` |
| `externalSecrets.*` | External Secrets Operator API versions, refresh policy and Password generator spec | see `values.yaml` |
| `api.authz.driver` | `builtin`, `cedar` or `authzen` | `builtin` |
| `api.authz.roleAssignments` | Role grants rendered into `authz-roles.yaml` | `{agents: agent}` |
| `api.agents.strictDisablePublicEndpoints` | Refuse anonymous agent traffic | `false` |
| `api.agents.*`, `api.worker.enabled`, `api.playback.*`, `api.artifacts.*`, `api.evidence.*` | API tuning; unset values keep the API defaults | unset |
| `api.agentBootstrap.*` | Optional Job that creates agent keys and Secrets | disabled |
| `api.ai.*` | AI suggestions (`provider: anthropic`, `baseUrl`, model, limits) | disabled |
| `<component>.podSecurityContext` / `<component>.securityContext` | Per-workload security contexts (`api`, `ui`, `dex`, `database.local`, `pgadmin4`); empty uses the global ones, then the hardened defaults | `{}` |
| `database.local.persistence.*` | Bundled PostgreSQL storage: the chart-created hostPath PV (as in 0.8.x), or a dynamically provisioned PVC with `createPersistentVolume: false` (recommended for fresh installs) | hostPath PV, `storageClass: standard` |
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
- **Workload hardening.** No container runs as root, init containers, hooks and the test pod included. Every pod
  meets the Pod Security `restricted` profile by default, with every optional workload on, without opt-outs: a numeric
  non-root user, `allowPrivilegeEscalation: false`, all capabilities dropped (none added), the `RuntimeDefault` seccomp
  profile, a read-only root filesystem, no sysctls, no host namespaces or hostPath volumes, and an `emptyDir` for every
  path the image writes. CI deploys the chart into namespaces that enforce `restricted`. Each workload takes its own
  `podSecurityContext` / `securityContext`, then the global ones, then these defaults:

  | Workload | User | Writable paths (emptyDir unless noted) | Notes |
  |----------|------|----------------------------------------|-------|
  | API pod | 65532 (all containers) | `/tmp`, the `publickey` volume | `generate-public-key` uses `alpine/openssl:3.5.9`, nothing installed at runtime |
  | UI (nginx) | 101 | `/var/cache/nginx`, `/run`, `/tmp` | listens on `ui.containerPort` (8080) through the chart's nginx server block (`ui.nginxConfig` replaces it); the Service port is unchanged |
  | Dex | 1001 | `/tmp` | |
  | PostgreSQL | 999 | data PVC (`fsGroup: 999`, `fsGroupChangePolicy: OnRootMismatch`), `/var/run/postgresql`, `/tmp` | data in the `pgdata` subdirectory of the volume, which postgres creates and owns |
  | pgAdmin 4 | 5050 | `/var/lib/pgadmin`, `/run/pgadmin`, `/tmp` | listens on 8080; its `config_distro.py` lives in `/var/lib/pgadmin` |
  | Agent bootstrap Job | 100 | `/tmp` | `curlimages/curl` |
  | `helm test` pod | 65534 | none | `busybox` `wget` |

- **PostgreSQL storage.** The defaults are the 0.8.x ones, so an upgrade with unchanged values keeps its volume: a
  chart-created hostPath PV (`persistence.createPersistentVolume: true`, at `persistence.path`, `storageClass:
  standard`). hostPath ignores `fsGroup` and the chart runs no root container and never chowns anything, so a **fresh**
  install on this PV needs the directory pre-created on the node and owned by `999:999` (the kubelet would create it
  root-owned). **Recommended for fresh installs:** `persistence.createPersistentVolume: false` with
  `persistence.storageClass` (`""` = the cluster's default StorageClass), for a dynamically provisioned PVC that
  `fsGroup: 999` makes writable without any root step. Postgres refuses a data directory it does not own, so the data
  lives in a subdirectory (`persistence.pgdataSubdir`, default `pgdata`) that postgres creates itself; that works
  whether the provisioner applies `fsGroup` or leaves the volume root root-owned and world-writable. Data a 0.8.x
  release initialised at the volume root is used where it is.
- **Credentials.** Use existing Secrets or External Secrets Operator (or `inMemory` / the seed for development): they
  are stable under `helm template` (Argo CD, Flux). The deprecated generated default is not: see Credentials.

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
4. **Credentials.** With unchanged values, an upgrade from 0.8.x keeps working exactly as before: the chart still
   generates the JWT key (a new one on every render) and keeps the Postgres, initial user and Dex passwords through
   `lookup`. That path is now **deprecated** (NOTES print a DEPRECATED notice) and will be removed in a future release.
   It is not GitOps-safe: under Argo CD / `helm template`, `lookup` returns nothing and the passwords are regenerated
   on every sync. Migrating to `existingSecret` is recommended. To keep the values your install already uses, copy the
   generated Secrets to new names and point the chart at the copies **before** upgrading (Helm deletes the
   chart-managed Secrets once they are no longer rendered):

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

   Do not switch an existing install to External Secrets Operator generation: ESO is for fresh installs only, and it
   would replace these values (see Credentials).

   An install that set `database.local.existingSecret` while keeping `createSecret: true` must now set
   `createSecret: false`.
5. **No container runs as root, and every pod meets Pod Security `restricted`** (see Security notes). Installs that
   set a component's or the global `podSecurityContext` / `securityContext` keep what they set.
   - **PostgreSQL storage.** The persistence defaults are unchanged from 0.8.x (the chart-created hostPath PV,
     `storageClass: standard`), so an upgrade with unchanged values keeps its PV, PVC and data. The data a 0.8.x
     release initialised at the volume root is used where it is (it is already owned by 999, because the old postgres
     container chowned it), and postgres now runs as 999. To move to a dynamically provisioned PVC
     (`createPersistentVolume: false`), dump and restore the database (`pg_dump` / `pg_restore`) into a fresh release:
     the PVC spec cannot change in place. Fresh installs on the hostPath PV must pre-create the directory owned by
     `999:999` (see Security notes).
   - **UI:** `ui.containerPort` defaults to `8080` (the Service targets it by name and keeps its port). A custom
     `ui.nginxConfig` must listen on it.
   - **pgAdmin:** `pgadmin4.containerPort` defaults to `8080`.
   - **`generate-public-key`** uses `alpine/openssl:3.5.9` with `openssl` as its command. If you overrode its image or
     command for the old `apk add` flow, update them: it now runs as non-root with a read-only root filesystem.
6. **Probes** now use `GET /api/health` (liveness) and `GET /api/health/ready` (readiness).
7. **`APP_PORT` is replaced by `CCF_APP_PORT`**, taken from `api.containerPort`.
8. **The UI container no longer gets an `API_URL` env var**; it never had an effect. Use `ui.apiUrl` or `webBaseUrl`.
9. **New API settings are optional.** Unset, the API defaults apply: playback on, artifacts 16 MiB / 8 concurrent,
   agent instances stale after 10m and pruned after 720h (24h for one-shot), 500 instances per agent, evidence
   subjects `off`, strict mode off.
10. **Agents.** Upgrade this chart before ccf-agent 0.4.0 (agent 0.9.0), then give each agent a key (see Agents).
