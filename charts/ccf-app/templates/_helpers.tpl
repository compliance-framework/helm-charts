{{/*
Expand the name of the chart.
*/}}
{{- define "ccf-app.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Create a default fully qualified app name.
We truncate at 63 chars because some Kubernetes name fields are limited to this (by the DNS naming spec).
If release name contains chart name it will be used as a full name.
*/}}
{{- define "ccf-app.fullname" -}}
{{- if .Values.fullnameOverride }}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- $name := default .Chart.Name .Values.nameOverride }}
{{- if contains $name .Release.Name }}
{{- .Release.Name | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- end }}
{{- end }}

{{/*
Create chart name and version as used by the chart label.
*/}}
{{- define "ccf-app.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels
*/}}
{{- define "ccf-app.labels" -}}
helm.sh/chart: {{ include "ccf-app.chart" . }}
{{ include "ccf-app.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- with .Values.commonLabels }}
{{ toYaml . }}
{{- end }}
{{- end }}

{{/*
Selector labels
*/}}
{{- define "ccf-app.selectorLabels" -}}
app.kubernetes.io/name: {{ include "ccf-app.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/*
Create the name of the service account to use
*/}}
{{- define "ccf-app.serviceAccountName" -}}
{{- if .Values.serviceAccount.create }}
{{- default (include "ccf-app.fullname" .) .Values.serviceAccount.name }}
{{- else }}
{{- default "default" .Values.serviceAccount.name }}
{{- end }}
{{- end }}

{{/*
Return the database password secret name and key based on configuration.
This function centralizes the logic for determining which secret and key to use
for database password authentication across all containers and init containers.
*/}}
{{- define "ccf-app.databasePasswordSecret" -}}
{{- if .Values.database.local.enabled -}}
  {{- if eq (include "ccf-app.psqlPasswordSource" .) "existingSecret" -}}
    {{- .Values.database.local.existingSecret -}}
  {{- else -}}
    {{- printf "%s-psql" (include "ccf-app.fullname" .) -}}
  {{- end -}}
{{- else -}}
  {{- if .Values.database.external.existingSecret -}}
    {{- .Values.database.external.existingSecret -}}
  {{- else -}}
    {{- fail "database.local.enabled is false but database.external.existingSecret is not set" -}}
  {{- end -}}
{{- end -}}
{{- end -}}

{{/*
Return the database password secret key based on configuration.
*/}}
{{- define "ccf-app.databasePasswordKey" -}}
{{- if .Values.database.local.enabled -}}
  {{- print "POSTGRES_PASSWORD" -}}
{{- else -}}
  {{- print .Values.database.external.passwordKey -}}
{{- end -}}
{{- end -}}

{{/*
Resolve and validate JWT runtime configuration once for reuse across templates.
*/}}
{{- define "ccf-app.jwtRuntimeConfig" -}}
{{- $jwtValues := default (dict) .Values.api.jwt -}}
{{- $jwtExistingSecretValues := default (dict) $jwtValues.existingSecret -}}
{{- $jwtPublicKeyGenerationValues := default (dict) $jwtValues.publicKeyGeneration -}}
{{- $jwtGenerationInitContainerValues := default (dict) $jwtPublicKeyGenerationValues.initContainer -}}
{{- $jwtGenerationImageValues := default (dict) $jwtGenerationInitContainerValues.image -}}
{{- $jwtSource := default "" $jwtValues.source -}}
{{- if not $jwtSource -}}
{{- fail "api.jwt.source is not set. Set it to 'existingSecret' (with api.jwt.existingSecret.name), 'externalSecret' (External Secrets Operator generates the key), 'inMemory' (development only: a new key on every API start, single replica), or the deprecated 'generated' (a new key on every helm upgrade and GitOps sync)" -}}
{{- end -}}
{{- if not (has $jwtSource (list "existingSecret" "externalSecret" "inMemory" "generated")) -}}
{{- fail "api.jwt.source must be one of 'existingSecret', 'externalSecret', 'inMemory', or the deprecated 'generated'" -}}
{{- end -}}
{{- $jwtUseExistingSecret := eq $jwtSource "existingSecret" -}}
{{- if and $jwtUseExistingSecret (empty $jwtExistingSecretValues.name) -}}
{{- fail "api.jwt.existingSecret.name is required when api.jwt.source is 'existingSecret'" -}}
{{- end -}}
{{- $jwtPublicGenerationEnabledValue := ternary $jwtPublicKeyGenerationValues.enabled true (hasKey $jwtPublicKeyGenerationValues "enabled") -}}
{{- /* The public key is derived by the init container from the private key when the chart
does not get it from a Secret: generated, externalSecret, or existingSecret without a publicKey. */ -}}
{{- $jwtPublicFromSecret := and $jwtUseExistingSecret (not (empty $jwtExistingSecretValues.publicKey)) -}}
{{- $jwtPublicGenerationEnabled := and (ne $jwtSource "inMemory") (not $jwtPublicFromSecret) $jwtPublicGenerationEnabledValue -}}
{{- $jwtFileMountsEnabled := ne $jwtSource "inMemory" -}}
source: {{ $jwtSource | quote }}
inMemory: {{ eq $jwtSource "inMemory" }}
useExistingSecret: {{ $jwtUseExistingSecret }}
publicKeyFromSecret: {{ $jwtPublicFromSecret }}
existingSecretName: {{ default "" $jwtExistingSecretValues.name | quote }}
existingPrivateKey: {{ default "private_key.pem" $jwtExistingSecretValues.privateKey | quote }}
existingPublicKey: {{ default "public_key.pem" $jwtExistingSecretValues.publicKey | quote }}
publicGenerationEnabled: {{ $jwtPublicGenerationEnabled }}
fileMountsEnabled: {{ $jwtFileMountsEnabled }}
generationContainerName: {{ default "generate-public-key" $jwtGenerationInitContainerValues.name | quote }}
generationImageRepository: {{ default "alpine/openssl" $jwtGenerationImageValues.repository | quote }}
generationImageTag: {{ default "3.5.9" $jwtGenerationImageValues.tag | quote }}
generationImagePullPolicy: {{ default "IfNotPresent" $jwtGenerationImageValues.pullPolicy | quote }}
generationCommand:
{{- toYaml (default (list "openssl") $jwtGenerationInitContainerValues.command) | nindent 2 }}
generationArgs:
{{- toYaml (default (list "rsa" "-in" "/var/ccf/private_key/private_key.pem" "-pubout" "-out" "/var/ccf/public_key/public_key.pem") $jwtGenerationInitContainerValues.args) | nindent 2 }}
{{- end -}}

{{/*
Mount of the authz role-assignment file. Every container that runs the API binary needs it:
`migrate up` reconciles the file into the database, and a missing file removes every
config-owned grant (api internal/authz/reconcile.go).
*/}}
{{- define "ccf-app.apiAuthzVolumeMount" -}}
- mountPath: /etc/ccf/authz-roles.yaml
  name: api-authz-config
  subPath: authz-roles.yaml
  readOnly: true
{{- end }}

{{/*
checksum/* pod annotations for the API: a change to any API ConfigMap or the chart-managed
API config Secret rolls the API pods, so new settings (including authz-roles.yaml, which the
API reconciles only at boot) take effect. Only templates that render something are listed.
The JWT and initial-user secrets are left out: they are generated, and a fresh value on every
`helm template` would roll the pods on every GitOps sync.
*/}}
{{- define "ccf-app.apiChecksumAnnotations" -}}
{{- $files := dict
  "checksum/config" "/configmap_api.yaml"
  "checksum/authz" "/configmap_api_authz.yaml"
  "checksum/authz-policies" "/configmap_api_authz_policies.yaml"
  "checksum/sso" "/configmap_api_sso.yaml"
  "checksum/email" "/configmap_api_email.yaml"
  "checksum/slack" "/configmap_api_slack.yaml"
  "checksum/workflow" "/configmap_api_workflow.yaml"
  "checksum/secret-config" "/secrets_api_config.yaml" -}}
{{- $out := dict -}}
{{- range $key, $file := $files -}}
{{- $rendered := include (print $.Template.BasePath $file) $ -}}
{{- if trim $rendered -}}
{{- $_ := set $out $key ($rendered | sha256sum) -}}
{{- end -}}
{{- end -}}
{{- toYaml $out -}}
{{- end }}

{{/*
Writable /tmp for containers that run /api with a read-only root filesystem (JWT bootstrap
lock file, multipart uploads over 32 MiB).
*/}}
{{- define "ccf-app.apiTmpVolumeMount" -}}
- mountPath: /tmp
  name: tmp
{{- end }}

{{/*
Operator cedar policy directory. When the chart mounts the policies (authz.cedar.policies or
existingConfigMap) it defaults to /etc/ccf/cedar-policies; otherwise it is policyDir as given
(possibly empty: no operator policies).
*/}}
{{- define "ccf-app.cedarPolicyDir" -}}
{{- $cedar := default (dict) .Values.api.authz.cedar -}}
{{- if or $cedar.policies $cedar.existingConfigMap -}}
{{- default "/etc/ccf/cedar-policies" $cedar.policyDir -}}
{{- else -}}
{{- default "" $cedar.policyDir -}}
{{- end -}}
{{- end }}

{{/*
Name of the ConfigMap holding the operator cedar policies the chart mounts, or empty.
*/}}
{{- define "ccf-app.cedarPoliciesConfigMap" -}}
{{- $cedar := default (dict) .Values.api.authz.cedar -}}
{{- if and $cedar.policies $cedar.existingConfigMap -}}
{{- fail "api.authz.cedar: set either policies or existingConfigMap, not both" -}}
{{- end -}}
{{- if $cedar.existingConfigMap -}}
{{- $cedar.existingConfigMap -}}
{{- else if $cedar.policies -}}
{{- printf "%s-api-authz-policies" (include "ccf-app.fullname" .) -}}
{{- end -}}
{{- end }}

{{/*
First-class API settings (agents, worker, playback, artifacts, evidence) as an env map for
the API ConfigMap. Only set values are included, except
CCF_STRICT_DISABLE_PUBLIC_AGENT_ENDPOINTS, which defaults to "false". A key that
api.extraConfig also sets is left to extraConfig, so existing installs that configured it
there render unchanged.
*/}}
{{- define "ccf-app.apiSettingsEnv" -}}
{{- $api := .Values.api -}}
{{- $agents := default (dict) $api.agents -}}
{{- $worker := default (dict) $api.worker -}}
{{- $playback := default (dict) $api.playback -}}
{{- $artifacts := default (dict) $api.artifacts -}}
{{- $evidence := default (dict) $api.evidence -}}
{{- $env := dict -}}
{{- $_ := set $env "CCF_STRICT_DISABLE_PUBLIC_AGENT_ENDPOINTS" (toString (default false $agents.strictDisablePublicEndpoints)) -}}
{{- $strings := dict
  "CCF_AGENT_INSTANCE_STALE_AFTER" $agents.instanceStaleAfter
  "CCF_AGENT_INSTANCE_RETENTION" $agents.instanceRetention
  "CCF_AGENT_INSTANCE_ONESHOT_RETENTION" $agents.oneShotInstanceRetention
  "CCF_AGENT_INSTANCE_PRUNE_SCHEDULE" $agents.instancePruneSchedule
  "CCF_PLAYBACK_TIMEOUT" $playback.timeout
  "CCF_EVIDENCE_REQUIRE_SUBJECT" $evidence.requireSubject -}}
{{- range $key, $val := $strings -}}
{{- if $val -}}
{{- $_ := set $env $key (toString $val) -}}
{{- end -}}
{{- end -}}
{{- $bools := dict
  "CCF_AGENT_INSTANCE_PRUNE_ENABLED" $agents.instancePruneEnabled
  "CCF_WORKER_ENABLED" $worker.enabled
  "CCF_PLAYBACK_ENABLED" $playback.enabled
  "CCF_MANUAL_EVIDENCE_REQUIRE_SUBJECT" $evidence.manualRequireSubject -}}
{{- range $key, $val := $bools -}}
{{- if not (kindIs "invalid" $val) -}}
{{- $_ := set $env $key (toString $val) -}}
{{- end -}}
{{- end -}}
{{- $ints := dict
  "CCF_AGENT_MAX_INSTANCES" $agents.maxInstances
  "CCF_PLAYBACK_MAX_BYTES" $playback.maxBytes
  "CCF_PLAYBACK_MAX_CONCURRENT" $playback.maxConcurrent
  "CCF_ARTIFACT_MAX_BYTES" $artifacts.maxBytes
  "CCF_ARTIFACT_MAX_CONCURRENT" $artifacts.maxConcurrent -}}
{{- range $key, $val := $ints -}}
{{- if not (kindIs "invalid" $val) -}}
{{- $_ := set $env $key (toString (int64 $val)) -}}
{{- end -}}
{{- end -}}
{{- range $key, $_ := (default (dict) $api.extraConfig) -}}
{{- $_ := unset $env $key -}}
{{- end -}}
{{- toYaml $env -}}
{{- end }}

{{/*
Return the base selector labels for a component.
*/}}
{{- define "ccf-app.componentBaseLabels" -}}
{{- $root := index . "root" -}}
{{- $name := index . "name" -}}
{{ include "ccf-app.selectorLabels" $root }}
app.kubernetes.io/component: {{ printf "%s-%s" (include "ccf-app.name" $root) $name }}
{{- end }}

{{/*
Merge helper for component metadata labels.
*/}}
{{- define "ccf-app.componentMetadataLabels" -}}
{{- $root := index . "root" -}}
{{- $name := index . "name" -}}
{{- $component := index . "component" -}}
{{- $labels := merge (dict) (include "ccf-app.componentBaseLabels" (dict "root" $root "name" $name) | fromYaml) -}}
{{- $labels = merge $labels (default (dict) $root.Values.commonLabels) -}}
{{- $labels = merge $labels (default (dict) (index $component "labels")) -}}
{{- toYaml $labels -}}
{{- end }}

{{/*
Merge helper for component pod template labels.
*/}}
{{- define "ccf-app.componentPodLabels" -}}
{{- $root := index . "root" -}}
{{- $name := index . "name" -}}
{{- $component := index . "component" -}}
{{- $labels := merge (dict) (include "ccf-app.componentBaseLabels" (dict "root" $root "name" $name) | fromYaml) -}}
{{- $labels = merge $labels (default (dict) $root.Values.commonLabels) -}}
{{- $labels = merge $labels (default (dict) $root.Values.podLabels) -}}
{{- $labels = merge $labels (default (dict) (index $component "podLabels")) -}}
{{- toYaml $labels -}}
{{- end }}

{{/*
Merge helper for component service labels.
*/}}
{{- define "ccf-app.componentServiceLabels" -}}
{{- $root := index . "root" -}}
{{- $name := index . "name" -}}
{{- $component := index . "component" -}}
{{- $labels := merge (dict) (include "ccf-app.componentBaseLabels" (dict "root" $root "name" $name) | fromYaml) -}}
{{- $labels = merge $labels (default (dict) $root.Values.commonLabels) -}}
{{- if and $component (index $component "service") -}}
{{- $labels = merge $labels (default (dict) (index (index $component "service") "labels")) -}}
{{- end -}}
{{- toYaml $labels -}}
{{- end }}

{{/*
webBaseUrl and URL/ingress helper functions
*/}}

{{- define "ccf-app.webBaseUrl" -}}
{{- $baseUrl := default "" .Values.webBaseUrl | trimSuffix "/" -}}
{{- if and $baseUrl (not (regexMatch "^https?://" $baseUrl)) -}}
{{- fail "webBaseUrl must be an absolute HTTP(S) URL (e.g., https://example.com) when non-empty" -}}
{{- end -}}
{{- $baseUrl -}}
{{- end -}}

{{- define "ccf-app.webBaseHost" -}}
{{- $base := include "ccf-app.webBaseUrl" . -}}
{{- include "ccf-app.urlHost" $base -}}
{{- end -}}

{{- define "ccf-app.apiWebBaseUrl" -}}
{{- $apiBaseUrl := default (include "ccf-app.webBaseUrl" .) .Values.api.webBaseUrl | trimSuffix "/" -}}
{{- if and $apiBaseUrl (not (regexMatch "^https?://" $apiBaseUrl)) -}}
{{- fail "api.webBaseUrl must be an absolute HTTP(S) URL (e.g., https://example.com) when non-empty" -}}
{{- end -}}
{{- $apiBaseUrl -}}
{{- end -}}

{{- define "ccf-app.apiCorsOrigins" -}}
{{- if .Values.api.corsOrigins -}}
{{- join "," .Values.api.corsOrigins -}}
{{- else -}}
{{- default "http://localhost:3000" (include "ccf-app.urlOrigin" (include "ccf-app.apiWebBaseUrl" .)) -}}
{{- end -}}
{{- end -}}

{{- define "ccf-app.urlOrigin" -}}
{{- $url := . | trimSuffix "/" -}}
{{- regexReplaceAll "^([^?#]*://[^/?#]*).*$" $url "${1}" -}}
{{- end -}}

{{- define "ccf-app.urlHost" -}}
{{- $withoutScheme := regexReplaceAll "^[A-Za-z][A-Za-z0-9+.-]*://" . "" -}}
{{- $hostPort := regexReplaceAll "[/?#].*$" $withoutScheme "" -}}
{{- regexReplaceAll ":[0-9]+$" $hostPort "" -}}
{{- end -}}

{{- define "ccf-app.urlPath" -}}
{{- $withoutScheme := regexReplaceAll "^[A-Za-z][A-Za-z0-9+.-]*://[^/]*" . "" -}}
{{- $path := regexReplaceAll "[?#].*$" $withoutScheme "" | trimSuffix "/" -}}
{{- if and $path (ne $path "/") -}}
{{- $path -}}
{{- end -}}
{{- end -}}

{{- define "ccf-app.apiIngressDefaultPath" -}}
{{- printf "%s/api/" (include "ccf-app.urlPath" (include "ccf-app.apiWebBaseUrl" .)) -}}
{{- end -}}

{{- define "ccf-app.uiIngressDefaultPath" -}}
{{- default "/" (include "ccf-app.urlPath" (include "ccf-app.webBaseUrl" .)) -}}
{{- end -}}

{{- define "ccf-app.dexIngressDefaultPath" -}}
{{- default "/" (include "ccf-app.urlPath" (include "ccf-app.dexIssuerUrl" .)) -}}
{{- end -}}

{{- define "ccf-app.apiSSOBaseUrl" -}}
{{- default (include "ccf-app.apiWebBaseUrl" .) .Values.api.sso.baseUrl | trimSuffix "/" -}}
{{- end -}}

{{- define "ccf-app.apiSSOCallbackUrl" -}}
{{- $url := default (printf "%s/api/auth/sso/callback" (include "ccf-app.apiWebBaseUrl" .)) .Values.api.sso.callbackUrl | trimSuffix "/" -}}
{{- if not (regexMatch "^https?://" $url) -}}
{{- fail "api.sso.callbackUrl, api.webBaseUrl, or webBaseUrl must resolve to an absolute HTTP(S) URL when SSO or Dex is enabled" -}}
{{- end -}}
{{- $url -}}
{{- end -}}

{{- define "ccf-app.apiSlackRedirectUrl" -}}
{{- $apiWebBaseUrl := include "ccf-app.apiWebBaseUrl" . -}}
{{- if .Values.api.slack.redirectUrl -}}
{{- .Values.api.slack.redirectUrl | trimSuffix "/" -}}
{{- else if $apiWebBaseUrl -}}
{{- printf "%s/api/auth/slack/link/callback" $apiWebBaseUrl -}}
{{- end -}}
{{- end -}}

{{- define "ccf-app.uiApiUrl" -}}
{{- default (include "ccf-app.webBaseUrl" .) .Values.ui.apiUrl | trimSuffix "/" -}}
{{- end -}}

{{- define "ccf-app.dexIssuerUrl" -}}
{{- $url := default (printf "%s/dex" (include "ccf-app.webBaseUrl" .)) .Values.dex.issuerUrl | trimSuffix "/" -}}
{{- if not (regexMatch "^https?://" $url) -}}
{{- fail "dex.issuerUrl or webBaseUrl must resolve to an absolute HTTP(S) URL when dex.enabled is true" -}}
{{- end -}}
{{- $url -}}
{{- end -}}

{{- define "ccf-app.dexWellKnownUrl" -}}
{{- if not .Values.dex.service.enabled -}}
{{- fail "dex.service.enabled must be true when dex.enabled is true" -}}
{{- end -}}
{{- $issuerUrl := include "ccf-app.dexIssuerUrl" . -}}
{{- $issuerPath := regexReplaceAll "^[A-Za-z][A-Za-z0-9+.-]*://[^/]*" $issuerUrl "" | trimSuffix "/" -}}
{{- printf "http://%s-dex:%v%s/.well-known/openid-configuration" (include "ccf-app.fullname" .) .Values.dex.service.port $issuerPath -}}
{{- end -}}

{{- define "ccf-app.dexSSOProviderName" -}}
{{- $name := required "dex.sso.name is required when dex.enabled is true" .Values.dex.sso.name -}}
{{- if not (regexMatch "^[A-Za-z_][A-Za-z0-9_]*$" $name) -}}
{{- fail "dex.sso.name must contain only letters, numbers, and underscores, and must not start with a number" -}}
{{- end -}}
{{- $name -}}
{{- end -}}

{{- define "ccf-app.dexSSOProviderEnvPrefix" -}}
{{- include "ccf-app.dexSSOProviderName" . | upper -}}
{{- end -}}

{{- define "ccf-app.dexClientSecretName" -}}
{{- if eq (include "ccf-app.dexClientSecretSource" .) "existingSecret" -}}
{{- .Values.dex.clientSecret.existingSecret -}}
{{- else -}}
{{- printf "%s-dex" (include "ccf-app.fullname" .) -}}
{{- end -}}
{{- end -}}

{{- define "ccf-app.dexClientSecretKey" -}}
{{- default "CCF_SSO_PROVIDERS_DEX_CLIENT_SECRET" .Values.dex.clientSecret.secretKey -}}
{{- end -}}

{{- define "ccf-app.dexClientSecretEnvName" -}}
{{- default "CCF_SSO_PROVIDERS_DEX_CLIENT_SECRET" .Values.dex.clientSecret.envName -}}
{{- end -}}
