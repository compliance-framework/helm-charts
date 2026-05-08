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
Return a base64 encoded database password. If the release already has a secret,
reuse its password to keep credentials stable across upgrades; otherwise generate
and return a new random password.
*/}}
{{- define "ccf-app.psqlPasswordB64" -}}
{{- $secretName := printf "%s-psql" (include "ccf-app.fullname" .) -}}
{{- $existing := lookup "v1" "Secret" .Release.Namespace $secretName -}}
{{- if and $existing (index $existing.data "POSTGRES_PASSWORD") -}}
{{- index $existing.data "POSTGRES_PASSWORD" -}}
{{- else if .Values.database.local.password -}}
{{- trim .Values.database.local.password | b64enc -}}
{{- else -}}
{{- randAlphaNum 32 | b64enc -}}
{{- end -}}
{{- end -}}

{{- define "ccf-app.initialUserPasword" -}}
{{- $secretName := printf "%s-initial-user-password" (include "ccf-app.fullname" .) -}}
{{- $existing := lookup "v1" "Secret" .Release.Namespace $secretName -}}
{{- if and $existing (index $existing.data "password") -}}
{{- index $existing.data "password" -}}
{{- else if .Values.api.user.password -}}
{{- trim .Values.api.user.password | b64enc -}}
{{- else -}}
{{- randAlphaNum 12 | b64enc -}}
{{- end -}}
{{- end -}}

{{/*
Return the database password secret name and key based on configuration.
This function centralizes the logic for determining which secret and key to use
for database password authentication across all containers and init containers.
*/}}
{{- define "ccf-app.databasePasswordSecret" -}}
{{- if .Values.database.local.enabled -}}
  {{- if .Values.database.local.createSecret -}}
    {{- printf "%s-psql" (include "ccf-app.fullname" .) -}}
  {{- else if .Values.database.local.existingSecret -}}
    {{- .Values.database.local.existingSecret -}}
  {{- else -}}
    {{- fail "database.local.enabled is true but neither createSecret nor existingSecret is set" -}}
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
{{- $jwtSource := default "generated" $jwtValues.source -}}
{{- if and (ne $jwtSource "generated") (ne $jwtSource "existingSecret") (ne $jwtSource "inMemory") -}}
{{- fail "api.jwt.source must be one of 'generated', 'existingSecret', or 'inMemory'" -}}
{{- end -}}
{{- $jwtUseExistingSecret := eq $jwtSource "existingSecret" -}}
{{- if and $jwtUseExistingSecret (empty $jwtExistingSecretValues.name) -}}
{{- fail "api.jwt.existingSecret.name is required when api.jwt.source is 'existingSecret'" -}}
{{- end -}}
{{- $jwtPublicGenerationEnabledValue := ternary $jwtPublicKeyGenerationValues.enabled true (hasKey $jwtPublicKeyGenerationValues "enabled") -}}
{{- $jwtPublicGenerationEnabled := and (eq $jwtSource "generated") $jwtPublicGenerationEnabledValue -}}
{{- $jwtFileMountsEnabled := ne $jwtSource "inMemory" -}}
{{- $apiHasConfigMounts := or .Values.api.sso.enabled .Values.api.email.enabled .Values.api.workflow.enabled .Values.api.slack.enabled -}}
{{- $apiHasConfigMounts = or $apiHasConfigMounts .Values.dex.enabled -}}
{{- $apiHasVolumeMounts := or $jwtFileMountsEnabled $apiHasConfigMounts -}}
source: {{ $jwtSource | quote }}
inMemory: {{ eq $jwtSource "inMemory" }}
useExistingSecret: {{ $jwtUseExistingSecret }}
existingSecretName: {{ default "" $jwtExistingSecretValues.name | quote }}
existingPrivateKey: {{ default "private_key.pem" $jwtExistingSecretValues.privateKey | quote }}
existingPublicKey: {{ default "public_key.pem" $jwtExistingSecretValues.publicKey | quote }}
publicGenerationEnabled: {{ $jwtPublicGenerationEnabled }}
fileMountsEnabled: {{ $jwtFileMountsEnabled }}
generationContainerName: {{ default "generate-public-key" $jwtGenerationInitContainerValues.name | quote }}
generationImageRepository: {{ default "alpine" $jwtGenerationImageValues.repository | quote }}
generationImageTag: {{ default "3.21" $jwtGenerationImageValues.tag | quote }}
generationImagePullPolicy: {{ default "IfNotPresent" $jwtGenerationImageValues.pullPolicy | quote }}
generationCommand:
{{- toYaml (default (list "sh" "-c") $jwtGenerationInitContainerValues.command) | nindent 2 }}
generationArgs:
{{- toYaml (default (list "apk add --no-cache openssl && echo \"Generating public key from private key...\" && openssl rsa -in /var/ccf/private_key/private_key.pem -pubout -out /var/ccf/public_key/public_key.pem") $jwtGenerationInitContainerValues.args) | nindent 2 }}
apiHasVolumeMounts: {{ $apiHasVolumeMounts }}
apiHasVolumes: {{ $apiHasVolumeMounts }}
{{- end -}}

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
Convert camelCase to snake_case
*/}}

{{- define "ccf-app.webBaseUrl" -}}
{{- default "" .Values.webBaseUrl | trimSuffix "/" -}}
{{- end -}}

{{- define "ccf-app.webBaseHost" -}}
{{- $base := include "ccf-app.webBaseUrl" . -}}
{{- $withoutScheme := regexReplaceAll "^[A-Za-z][A-Za-z0-9+.-]*://" $base "" -}}
{{- $hostPort := regexReplaceAll "/.*$" $withoutScheme "" -}}
{{- regexReplaceAll ":[0-9]+$" $hostPort "" -}}
{{- end -}}

{{- define "ccf-app.apiWebBaseUrl" -}}
{{- default (include "ccf-app.webBaseUrl" .) .Values.api.webBaseUrl | trimSuffix "/" -}}
{{- end -}}

{{- define "ccf-app.apiCorsOrigins" -}}
{{- if .Values.api.corsOrigins -}}
{{- join "," .Values.api.corsOrigins -}}
{{- else -}}
{{- include "ccf-app.urlOrigin" (include "ccf-app.apiWebBaseUrl" .) -}}
{{- end -}}
{{- end -}}

{{- define "ccf-app.urlOrigin" -}}
{{- $url := . | trimSuffix "/" -}}
{{- regexReplaceAll "^([^?#]*://[^/?#]*).*$" $url "${1}" -}}
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
{{- if .Values.dex.clientSecret.createSecret -}}
{{- printf "%s-dex" (include "ccf-app.fullname" .) -}}
{{- else if .Values.dex.clientSecret.existingSecret -}}
{{- .Values.dex.clientSecret.existingSecret -}}
{{- else -}}
{{- fail "dex.clientSecret.existingSecret is required when dex.clientSecret.createSecret is false" -}}
{{- end -}}
{{- end -}}

{{- define "ccf-app.dexClientSecretKey" -}}
{{- default "CCF_SSO_PROVIDERS_DEX_CLIENT_SECRET" .Values.dex.clientSecret.secretKey -}}
{{- end -}}

{{- define "ccf-app.dexClientSecretEnvName" -}}
{{- default "CCF_SSO_PROVIDERS_DEX_CLIENT_SECRET" .Values.dex.clientSecret.envName -}}
{{- end -}}

{{- define "ccf-app.dexClientSecretB64" -}}
{{- $secretName := printf "%s-dex" (include "ccf-app.fullname" .) -}}
{{- $key := include "ccf-app.dexClientSecretKey" . -}}
{{- $existing := lookup "v1" "Secret" .Release.Namespace $secretName -}}
{{- if and $existing (index $existing.data $key) -}}
{{- index $existing.data $key -}}
{{- else if .Values.dex.clientSecret.value -}}
{{- trim .Values.dex.clientSecret.value | b64enc -}}
{{- else -}}
{{- randAlphaNum 32 | b64enc -}}
{{- end -}}
{{- end -}}
