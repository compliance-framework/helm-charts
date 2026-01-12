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
| `image.repository` | Agent image repository | `ghcr.io/compliance-framework/agent` |
| `image.tag` | Agent image tag | `""` (uses appVersion) |
| `image.pullPolicy` | Image pull policy | `IfNotPresent` |
| `agent.hostname` | Agent hostname for identification | `""` (uses pod name) |
| `agent.daemon` | Run agent in daemon mode | `false` |
| `agent.verbosity` | Logging verbosity (0-3) | `0` |
| `agent.api.url` | CCF API URL | `http://ccf-api:8080` |

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
