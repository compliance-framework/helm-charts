# CCF Helm Chart

This chart (`ccf`) deploys the Continuous Compliance Framework: the API, the UI, and optionally a bundled PostgreSQL,
Dex and pgAdmin. Agents are deployed separately with the [`ccf-agent`](../ccf-agent) chart.

## Installation

```bash
helm install ccf oci://ghcr.io/compliance-framework/helm-charts/ccf \
  --namespace ccf --create-namespace \
  --set webBaseUrl=https://ccf.example.com
```

The chart creates an initial admin user, `api.user.email` (default `admin@localhost`). Its password is
`api.user.password`, or a generated one stored in the `<fullname>-initial-user-password` Secret:

```bash
kubectl -n ccf get secret ccf-initial-user-password -o jsonpath='{.data.password}' | base64 -d
```

## Key values

The full list is in [`values.yaml`](./values.yaml), with a comment per value.

| Value | Description | Default |
|-------|-------------|---------|
| `webBaseUrl` | Public URL of the UI; derives the API URL, CORS origin, SSO callback and ingress hosts | `""` |
| `api.image.tag` / `ui.image.tag` | API and UI image tags | see `values.yaml` |
| `api.jwt.source` | `generated`, `existingSecret` or `inMemory` | `generated` |
| `api.authz.driver` | `builtin`, `cedar` or `authzen` | `builtin` |
| `api.authz.roleAssignments` | Role grants rendered into `authz-roles.yaml` | `{agents: agent}` |
| `api.agents.strictDisablePublicEndpoints` | Refuse anonymous agent traffic | `false` |
| `api.agents.*`, `api.worker.enabled`, `api.playback.*`, `api.artifacts.*`, `api.evidence.*` | API tuning; unset values keep the API defaults | unset |
| `api.agentBootstrap.*` | Optional Job that creates agent keys and Secrets | disabled |
| `api.ai.*` | AI suggestions (`provider: anthropic`, `baseUrl`, model, limits) | disabled |
| `api.podSecurityContext` / `api.securityContext` | API security contexts; empty uses the hardened defaults below | `{}` |
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

- The Job logs in as the chart's initial user by default (`adminCredentials` overrides it). Under the `cedar` driver
  that user needs the `admin` role in `api.authz.roleAssignments.users`.
- A Secret that already exists is left alone, so re-runs on upgrade are no-ops. Delete the Secret (and revoke the old
  key in the UI) to issue a new key.
- The Secrets are not part of the release, so `helm uninstall` keeps them.
- The Job has a ServiceAccount and, in each target namespace, a Role allowing `get` on the listed Secrets and `create`
  on Secrets. All are hook resources, deleted when the Job succeeds.
- The default image, `alpine:3.21`, installs `curl` and `jq` with `apk` when it starts, which needs root and egress
  to the Alpine mirror. Set `api.agentBootstrap.image` to an image that ships both to skip that step.
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
- **API pod.** Unless `api.podSecurityContext` / `api.securityContext` (or the global `podSecurityContext` /
  `securityContext`) are set, the API container and its `migrate-db` and `create-user` init containers run as uid/gid
  `65532` with `runAsNonRoot`, a read-only root filesystem, no privilege escalation, no capabilities and the
  `RuntimeDefault` seccomp profile; the pod uses `fsGroup: 65532`. The API writes only to `/tmp`, an `emptyDir`. The
  `generate-public-key` init container still runs as root, because it installs openssl with `apk`.
- **JWT key.** With `api.jwt.source: generated`, the chart keeps the key in the release's existing Secret across
  upgrades. Tools that render with `helm template` (for example Argo CD) cannot read it back and generate a new key
  on every render, which logs everyone out: use `api.jwt.source: existingSecret` there.

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
4. **The JWT key is no longer rotated on upgrade** (see Security notes for `helm template` users).
5. **The API pod is hardened** (non-root, read-only root filesystem). Installs that set `api.securityContext`,
   `api.podSecurityContext` or the global ones keep what they set.
6. **Probes** now use `GET /api/health` (liveness) and `GET /api/health/ready` (readiness).
7. **`APP_PORT` is replaced by `CCF_APP_PORT`**, taken from `api.containerPort`.
8. **The UI container no longer gets an `API_URL` env var**; it never had an effect. Use `ui.apiUrl` or `webBaseUrl`.
9. **New API settings are optional.** Unset, the API defaults apply: playback on, artifacts 16 MiB / 8 concurrent,
   agent instances stale after 10m and pruned after 720h (24h for one-shot), 500 instances per agent, evidence
   subjects `off`, strict mode off.
10. **Agents.** Upgrade this chart before ccf-agent 0.4.0 (agent 0.9.0), then give each agent a key (see Agents).
