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
| `agent.hostname` | Agent hostname for identification | `""` (uses pod name) |
| `agent.daemon` | Run agent in daemon mode | `true` |
| `agent.instanceId` | Fixed agent instance ID (`CCF_INSTANCE_ID`, a UUID); the chart never generates one | `""` |
| `agent.verbosity` | Logging verbosity (0-3) | `0` |
| `agent.agentEvidence.enabled` | Enable agent evidence reporting | `false` |
| `agent.agentEvidence.interval` | Evidence reporting interval | `1h` |
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

### Plugin Configuration

Plugins are configured under `agent.plugins`. Each plugin can have:
- `schedule`: Cron schedule for plugin execution
- `source`: Container image for the plugin
- `policies`: List of policy bundles to evaluate
- `config`: Plugin-specific configuration
- `labels`: Labels for organizing compliance data

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
