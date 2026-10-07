# CCF Agent Helm Chart

This Helm chart deploys the CCF Agent, which runs compliance plugins for continuous monitoring and policy evaluation.

## Overview

The CCF Agent is a worker component that:
- Connects to the CCF API
- Runs compliance plugins on a schedule
- Collects compliance data from various sources (Jira, GitHub, etc.)
- Evaluates policies against collected data

## Prerequisites

- Kubernetes 1.19+
- Helm 3.0+
- CCF API deployed and accessible

## Installation

### Basic Installation

```bash
helm install ccf-agent ./ccf-agent \
  --set agent.api.url=http://ccf-api:8080
```

### Installation with Plugins

```bash
helm install ccf-agent ./ccf-agent \
  --values my-values.yaml
```

## Configuration

### Core Configuration

| Parameter | Description | Default |
|-----------|-------------|---------|
| `replicaCount` | Number of agent replicas | `1` |
| `strategy` | Deployment update strategy | `{type: Recreate}` |
| `terminationGracePeriodSeconds` | Seconds to wait after SIGTERM (the agent takes up to 30s to stop) | `45` |
| `image.repository` | Agent image repository | `ghcr.io/compliance-framework/agent` |
| `image.tag` | Agent image tag | `""` (uses appVersion) |
| `image.pullPolicy` | Image pull policy | `IfNotPresent` |
| `agent.hostname` | Deprecated, no effect (the agent uses the pod name) | `""` |
| `agent.daemon` | Run agent in daemon mode | `true` |
| `agent.instanceId` | Fixed agent instance ID (`CCF_INSTANCE_ID`, a UUID); the chart never generates one | `""` |
| `agent.verbosity` | Logging verbosity (0-3) | `0` |
| `agent.agentEvidence.enabled` | Enable agent evidence reporting | `false` |
| `agent.agentEvidence.interval` | Evidence reporting interval | `1h` |
| `agent.agentEvidence.emitOnRunCompletion` | `agent_evidence.emit_on_run_completion`: also emit agent evidence when a run completes | `null` (agent default `true`) |
| `agent.remoteConfig.mode` | `remote_config.mode`: `off`, `report`, `apply_safe` or `apply_all` | `""` (agent default) |
| `agent.remoteConfig.pollInterval` | `remote_config.poll_interval`, a Go duration of at least `15s` | `""` (agent default `60s`) |
| `agent.remoteConfig.trustedSources` | `remote_config.trusted_sources`, globs of sources an overlay may add | `[]` |
| `agent.remoteConfig.overridableConfigFlags` | `remote_config.overridable_config_flags`, plugin config keys an overlay may change | `[]` |
| `agent.remoteConfig.allowLocalSources` | `remote_config.allow_local_sources` | `null` (agent default `false`) |
| `agent.api.url` | CCF API URL | `http://ccf-api:8080` |
| `agent.api.auth.enabled` | Enable API authentication | `false` |
| `agent.api.auth.createSecret` | Create a secret with credentials | `false` |
| `agent.api.auth.existingSecret` | Reference an existing secret | `""` |
| `agent.api.auth.clientId.value` | Client ID value (a UUID) | `""` |
| `agent.api.auth.clientId.secretKeyRef` | Key in `existingSecret` holding the client ID | `""` (`CCF_API_AUTH_CLIENT_ID`) |
| `agent.api.auth.clientSecret.value` | Client secret value | `""` |
| `agent.api.auth.clientSecret.secretKeyRef` | Key in `existingSecret` holding the client secret | `""` (`CCF_API_AUTH_CLIENT_SECRET`) |

### Agent State

The chart sets `CCF_STATE_DIR=/app/.compliance-framework/state/agent`, on the `emptyDir` mounted at
`/app/.compliance-framework`. The agent keeps its instance ID and its remote-configuration cache there. The state
survives container restarts, but not a new pod: each new pod (an upgrade, a rescheduled pod, a values change that
rolls the Deployment) registers as a new agent instance in the API. The API prunes stale instances after its retention
period. Set `agent.instanceId` to pin the ID instead; never share one ID between replicas.

The Deployment uses the `Recreate` strategy, so the old pod stops before the new one starts.

### Image Flavours

The agent is published as three images:

| Image | Base | Use with this chart |
|-------|------|---------------------|
| `ghcr.io/compliance-framework/agent` | distroless, runs as root by default | The default. The chart forces uid/gid `1000` and a read-only root filesystem. |
| `ghcr.io/compliance-framework/agent-custodian` | `cloudcustodian/c7n`, non-root `custodian` user | For the Cloud Custodian plugins. Run it as uid `1001` (see below). |
| `ghcr.io/compliance-framework/agent-ci` | `debian:bookworm-slim` | For CI jobs (`submit-evidence`). Not for this chart. |

The chart's `command` (`./concom agent -c /config/config.yml`) works for both `agent` and `agent-custodian`. For
`agent-custodian`, run as the `custodian` user and give it a writable `HOME`:

```yaml
image:
  repository: ghcr.io/compliance-framework/agent-custodian
podSecurityContext:
  runAsNonRoot: true
  runAsUser: 1001
  fsGroup: 1001
  seccompProfile:
    type: RuntimeDefault
securityContext:
  allowPrivilegeEscalation: false
  readOnlyRootFilesystem: true
  runAsNonRoot: true
  runAsUser: 1001
  capabilities:
    drop: [ALL]
  seccompProfile:
    type: RuntimeDefault
extraEnv:
  - name: HOME
    value: /home/custodian
volumes:
  - name: custodian-home
    emptyDir: {}
volumeMounts:
  - name: custodian-home
    mountPath: /home/custodian
```

### Pod Security

The default pod and container security contexts meet the Pod Security `restricted` profile: uid 1000, seccomp
`RuntimeDefault`, no privilege escalation, all capabilities dropped and a read-only root filesystem, with emptyDirs for
`/tmp` and `/app/.compliance-framework`. No container runs as root. If you override `podSecurityContext` or
`securityContext` (for example for `agent-custodian`, above), keep these fields, and give any `initContainers` you add
the same restrictions.

### Replicas and Autoscaling

Every replica of a release gets the same configuration and the same API key, so the replicas write the **same
evidence streams** (the `_agent` label is the key's `client_id`, or a hash of the configuration without credentials)
and each replica runs every plugin. To split work, install one release per set of plugins, each with its own key.
`replicaCount` and `autoscaling` remain available.

### Plugin Configuration

Plugins are configured under `agent.plugins`. Each plugin can have:
- `schedule`: Cron schedule for plugin execution
- `source`: Container image for the plugin
- `policies`: List of policy bundles to evaluate
- `config`: Plugin-specific configuration
- `labels`: Labels for organizing compliance data
- `enabled`: set to `false` to disable a plugin without removing it. A disabled plugin gets no schedule, no download
  and no run state, but it stays in the configuration the agent reports.

The block is passed to the agent as-is, so other agent plugin keys (`protocol_version`, `policy_data`,
`policy_behavior`) work too.

#### `${env:NAME}` placeholders

A value in `plugins.<name>.config` may reference an environment variable, whole or embedded:
`token: "${env:GITHUB_TOKEN}"` or `dsn: "postgres://app:${env:PG_PASSWORD}@db:5432/app"`. The chart passes the
placeholder through unchanged and the agent resolves it. Placeholders:

- are resolved **only** in `plugins.*.config`; anywhere else they stay literal strings;
- can never reference `CCF_API_AUTH_*`;
- appear unresolved in the configuration the agent reports, so the secret value never leaves the pod.

Provide the variables with `secretRefs` (or `extraEnv` / `extraEnvFrom`):

```yaml
agent:
  plugins:
    github:
      source: ghcr.io/compliance-framework/plugin-github:v1.0.0
      config:
        token: "${env:GITHUB_TOKEN}"
secretRefs:
  - name: github-token
    keys:
      - envName: GITHUB_TOKEN
        secretKey: token
```

Plugin processes receive the agent's environment except `CCF_API_AUTH_*`, so plugins never see the agent's API
credentials.

Example:

```yaml
agent:
  plugins:
    jira:
      schedule: "*/5 * * * *"
      source: ghcr.io/compliance-framework/plugin-jira:v0.1.1
      policies:
        - ghcr.io/compliance-framework/plugin-jira-policies:v0.1.1
      config:
        base_url: https://your-instance.atlassian.net
        auth_type: oauth2
        project_keys: "PROJECT"
      labels:
        tier: change-management
        team: ccf
```

### API Authentication

The agent authenticates to the CCF API with an agent service-account key: a `client-id` (a UUID) and a
`client-secret`. Create one in the CCF UI under **Admin -> Agents**, or let the ccf-app chart's agent bootstrap Job
create it. The chart passes the key to the agent as `CCF_API_AUTH_CLIENT_ID` and `CCF_API_AUTH_CLIENT_SECRET`. Set
both or neither: without credentials the agent runs anonymously. Plugins never receive these variables.

Credentials can be configured in three ways:

#### Option 1: Reference an existing secret (recommended)

```yaml
agent:
  api:
    auth:
      enabled: true
      existingSecret: "my-agent-credentials"
```

The secret must hold the keys `CCF_API_AUTH_CLIENT_ID` and `CCF_API_AUTH_CLIENT_SECRET`, which are the keys the ccf-app
agent bootstrap Job writes. To read other keys, set `clientId.secretKeyRef` and `clientSecret.secretKeyRef`:

```yaml
agent:
  api:
    auth:
      enabled: true
      existingSecret: "my-api-credentials"
      clientId:
        secretKeyRef: "client-id"
      clientSecret:
        secretKeyRef: "client-secret"
```

#### Option 2: Create a new secret with credentials

```yaml
agent:
  api:
    auth:
      enabled: true
      createSecret: true
      clientId:
        value: "123e4567-e89b-12d3-a456-426614174000"
      clientSecret:
        value: "your-client-secret"
```

This creates a Kubernetes Secret named `<fullname>-auth` (e.g., `ccf-agent-auth` when installed with release name
`ccf-agent`, or `myrelease-ccf-agent-auth` when installed with release name `myrelease`) with the keys
`CCF_API_AUTH_CLIENT_ID` and `CCF_API_AUTH_CLIENT_SECRET`.

#### Option 3: Use plain values (for development only)

```yaml
agent:
  api:
    auth:
      enabled: true
      clientId:
        value: "123e4567-e89b-12d3-a456-426614174000"
      clientSecret:
        value: "your-client-secret"
```

This sets the credentials as environment variables directly (not recommended for production).

Rendering fails when only one of the two values is set, or when `clientId.value` is not a UUID.

### Remote Configuration

With API credentials, agent v0.9.0 reports its configuration to the API and can apply a configuration overlay stored
there. `agent.remoteConfig` renders the agent's `remote_config` block. Only the keys you set are rendered; with none
set there is no block and the agent defaults apply: mode `report` with credentials, `off` without (missing credentials
always force `off`). `report` sends configuration reports but never fetches an overlay, so applying remote changes is
opt-in:

```yaml
agent:
  remoteConfig:
    mode: apply_safe            # or apply_all; quote "off" if you set it
    pollInterval: 60s           # at least 15s
    trustedSources:
      - ghcr.io/compliance-framework/*
    overridableConfigFlags:
      - "github:token"
```

`remote_config` is set locally only: an overlay that tries to change it (or `api` or `daemon`) is rejected. See the
agent's [configuration docs](https://github.com/compliance-framework/agent/blob/main/docs/configuration.md#remote-configuration)
for how changes are classified as safe, unsafe or forbidden.

### Secret References

Plugin credentials should be provided via Kubernetes secrets and referenced using `secretRefs`:

```yaml
secretRefs:
  - name: ccf-plugin-jira
    keys:
      - envName: CCF_PLUGINS_JIRA_CONFIG_CLIENT_ID
        secretKey: client_id
      - envName: CCF_PLUGINS_JIRA_CONFIG_CLIENT_SECRET
        secretKey: client_secret
  
  - name: ccf-plugin-github
    keys:
      - envName: CCF_PLUGINS_GITHUB_CONFIG_TOKEN
        secretKey: token
```

### Resource Configuration

| Parameter | Description | Default |
|-----------|-------------|---------|
| `resources.limits.cpu` | CPU limit | `500m` |
| `resources.limits.memory` | Memory limit | `512Mi` |
| `resources.requests.cpu` | CPU request | `100m` |
| `resources.requests.memory` | Memory request | `128Mi` |

### Autoscaling

| Parameter | Description | Default |
|-----------|-------------|---------|
| `autoscaling.enabled` | Enable HPA | `false` |
| `autoscaling.minReplicas` | Minimum replicas | `1` |
| `autoscaling.maxReplicas` | Maximum replicas | `10` |
| `autoscaling.targetCPUUtilizationPercentage` | Target CPU % | `80` |

## Example Values Files

### Todo Demo Agent

```yaml
agent:
  api:
    url: http://ccf-api:8080
  
  plugins:
    jira:
      schedule: "*/2 * * * *"
      source: ghcr.io/compliance-framework/plugin-jira:v0.1.1
      policies:
        - ghcr.io/compliance-framework/plugin-jira-policies:v0.1.1
      config:
        base_url: https://container-solutions.atlassian.net
        auth_type: oauth2
        project_keys: "TSTCHG"
        change_request_issue_types: "Request a change"
      labels:
        tier: change-management
        team: ccf
    
    dependabot:
      schedule: "*/2 * * * *"
      source: ghcr.io/compliance-framework/plugin-dependabot:v0.3.4
      policies:
        - ghcr.io/compliance-framework/plugin-dependabot-policies:v0.3.0
      config:
        organization: compliance-framework
        included-repositories: todo-app,ui,agent,api
      labels:
        tier: vcs
        team: ccf

secretRefs:
  - name: ccf-plugin-jira
    keys:
      - envName: CCF_PLUGINS_JIRA_CONFIG_CLIENT_ID
        secretKey: client_id
      - envName: CCF_PLUGINS_JIRA_CONFIG_CLIENT_SECRET
        secretKey: client_secret
  
  - name: ccf-plugin-github
    keys:
      - envName: CCF_PLUGINS_DEPENDABOT_CONFIG_TOKEN
        secretKey: token
```

## Upgrading

```bash
helm upgrade ccf-agent ./ccf-agent \
  --values my-values.yaml
```

### 0.3.x to 0.4.0 (agent 0.6.1 to 0.9.0)

Upgrade the ccf-app chart (API 0.21.0) first. Agent 0.9.0 also works with older APIs, without remote configuration
(and without artifact digests before API 0.20.0).

1. **Get credentials.** Create an agent and a key in the CCF UI under **Admin -> Agents**, or let the ccf-app agent
   bootstrap Job (`api.agentBootstrap`) create them and write a Secret. Use one key per release. Reference the Secret
   with `agent.api.auth.existingSecret`; its keys default to `CCF_API_AUTH_CLIENT_ID` and `CCF_API_AUTH_CLIENT_SECRET`.
2. **Authentication starts working.** Earlier charts passed the credentials as `CCF_AGENT_API_AUTH_*`, which the agent
   never read, so agents with `agent.api.auth.enabled: true` ran anonymously. After the upgrade they authenticate:
   - the `_agent` evidence label changes from a configuration hash to the key's `client_id`. Evidence UUIDs derive from
     labels, so **new evidence streams start** and the old ones stop updating;
   - the agent reports its configuration to the API and appears as an instance under its agent;
   - plugins no longer see the credentials.
   A chart-created `<fullname>-auth` Secret is re-created with the new key names. An `existingSecret` that used other
   key names keeps working through `clientId.secretKeyRef` / `clientSecret.secretKeyRef`. A non-UUID `clientId.value`,
   or only one of the two values, now fails to render.
3. **`agent.daemon` now defaults to `true`.** Set `agent.daemon: false` explicitly to keep the run-once behaviour.
4. **The Deployment strategy is `Recreate`**, and `terminationGracePeriodSeconds` is `45`. The old pod stops before the
   new one starts. Set `strategy.type: RollingUpdate` to keep rolling updates.
5. **Applying remote changes is opt-in.** With credentials the agent defaults to `remote_config.mode: report`, which
   reports its configuration but never fetches or applies an overlay. Set `agent.remoteConfig.mode: apply_safe` or
   `apply_all` (with `trustedSources` and `overridableConfigFlags`) to apply remote changes.
6. **State.** `CCF_STATE_DIR` is pinned on the existing emptyDir, so every new pod (including this upgrade) registers a
   new agent instance in the API.
7. `agent.hostname` is deprecated and has no effect.

## Uninstalling

```bash
helm uninstall ccf-agent
```

## Troubleshooting

### Check Agent Logs

```bash
kubectl logs -f deployment/ccf-agent
```

### View Configuration

```bash
kubectl get configmap ccf-agent-config -o yaml
```

### Verify Secrets

```bash
kubectl get secrets
kubectl describe secret ccf-plugin-jira
```

## Support

For issues and questions:
- GitHub: https://github.com/compliance-framework/agent
- Documentation: https://github.com/compliance-framework/helm-charts
