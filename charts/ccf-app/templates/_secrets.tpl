{{/*
Credential sources. The chart never generates or looks up a secret at render time: `lookup`
returns nothing under `helm template` (Argo CD, Flux), so a generated value changes on every
render. Each credential comes from, in this order:
  existingSecret  a Secret the operator provides (the primary path);
  externalSecret  an ExternalSecret the chart renders; External Secrets Operator generates the
                  value once (refreshPolicy CreatedOnce);
  value           an explicit value in the chart values (rendered into a chart Secret);
  seed            devSecrets.seed: a value derived from an explicit seed. Stable across renders,
                  but anyone who knows the seed knows the credential: development only;
and rendering fails when none is set.
*/}}

{{/*
dev-only derived credential: hex sha256 of "ccf:<purpose>:<seed>", truncated to 32 characters.
Usage: include "ccf-app.devSecret" (dict "root" . "purpose" "postgres")
*/}}
{{- define "ccf-app.devSecret" -}}
{{- $seed := default "" (dig "seed" "" (default (dict) .root.Values.devSecrets)) -}}
{{- if $seed -}}
{{- printf "ccf:%s:%s" .purpose $seed | sha256sum | trunc 32 -}}
{{- end -}}
{{- end }}

{{/* Postgres password (bundled PostgreSQL): existingSecret | externalSecret | value | seed | "" */}}
{{- define "ccf-app.psqlPasswordSource" -}}
{{- $local := .Values.database.local -}}
{{- if and $local.existingSecret $local.createSecret -}}
{{- fail "database.local: existingSecret and createSecret are both set; set createSecret: false to use the existing Secret" -}}
{{- end -}}
{{- if $local.existingSecret -}}existingSecret
{{- else if (dig "externalSecret" "enabled" false $local) -}}externalSecret
{{- else if and $local.createSecret $local.password -}}value
{{- else if and $local.createSecret (include "ccf-app.devSecret" (dict "root" . "purpose" "postgres")) -}}seed
{{- end -}}
{{- end }}

{{- define "ccf-app.psqlPassword" -}}
{{- if .Values.database.local.password -}}
{{- trim .Values.database.local.password -}}
{{- else -}}
{{- include "ccf-app.devSecret" (dict "root" . "purpose" "postgres") -}}
{{- end -}}
{{- end }}

{{/* Initial admin user password: existingSecret | externalSecret | value | seed | "" */}}
{{- define "ccf-app.initialUserPasswordSource" -}}
{{- $user := .Values.api.user -}}
{{- if $user.existingSecret -}}existingSecret
{{- else if (dig "externalSecret" "enabled" false $user) -}}externalSecret
{{- else if $user.password -}}value
{{- else if include "ccf-app.devSecret" (dict "root" . "purpose" "initial-user") -}}seed
{{- end -}}
{{- end }}

{{- define "ccf-app.initialUserPassword" -}}
{{- if .Values.api.user.password -}}
{{- trim .Values.api.user.password -}}
{{- else -}}
{{- include "ccf-app.devSecret" (dict "root" . "purpose" "initial-user") -}}
{{- end -}}
{{- end }}

{{/* Secret and key holding the initial admin user's password. */}}
{{- define "ccf-app.initialUserPasswordSecret" -}}
{{- if eq (include "ccf-app.initialUserPasswordSource" .) "existingSecret" -}}
{{- .Values.api.user.existingSecret -}}
{{- else -}}
{{- printf "%s-initial-user-password" (include "ccf-app.fullname" .) -}}
{{- end -}}
{{- end }}

{{- define "ccf-app.initialUserPasswordKey" -}}
{{- if eq (include "ccf-app.initialUserPasswordSource" .) "existingSecret" -}}
{{- default "password" .Values.api.user.passwordKey -}}
{{- else -}}
password
{{- end -}}
{{- end }}

{{/* Dex static client secret: existingSecret | externalSecret | value | seed | "" */}}
{{- define "ccf-app.dexClientSecretSource" -}}
{{- $cs := .Values.dex.clientSecret -}}
{{- if and $cs.existingSecret $cs.createSecret -}}
{{- fail "dex.clientSecret: existingSecret and createSecret are both set; set createSecret: false to use the existing Secret" -}}
{{- end -}}
{{- if $cs.existingSecret -}}existingSecret
{{- else if (dig "externalSecret" "enabled" false $cs) -}}externalSecret
{{- else if and $cs.createSecret $cs.value -}}value
{{- else if and $cs.createSecret (include "ccf-app.devSecret" (dict "root" . "purpose" "dex-client")) -}}seed
{{- end -}}
{{- end }}

{{- define "ccf-app.dexClientSecret" -}}
{{- if .Values.dex.clientSecret.value -}}
{{- trim .Values.dex.clientSecret.value -}}
{{- else -}}
{{- include "ccf-app.devSecret" (dict "root" . "purpose" "dex-client") -}}
{{- end -}}
{{- end }}

{{/*
Fail rendering, naming every missing credential and the values that provide it.
*/}}
{{- define "ccf-app.validateSecretSources" -}}
{{- $names := list -}}
{{- $missing := list -}}
{{- if not (has (default "" .Values.api.jwt.source) (list "existingSecret" "externalSecret" "inMemory" "generated")) -}}
{{- $names = append $names "JWT signing key" -}}
{{- $missing = append $missing "- JWT signing key: api.jwt.source=existingSecret (+ api.jwt.existingSecret.name), api.jwt.source=externalSecret (External Secrets Operator), or api.jwt.source=inMemory (development only)" -}}
{{- end -}}
{{- if and .Values.database.local.enabled (not (include "ccf-app.psqlPasswordSource" .)) -}}
{{- $names = append $names "PostgreSQL password" -}}
{{- $missing = append $missing "- PostgreSQL password: database.local.existingSecret (with createSecret: false; key POSTGRES_PASSWORD), database.local.externalSecret.enabled=true (External Secrets Operator), database.local.password, or devSecrets.seed (development only)" -}}
{{- end -}}
{{- if not (include "ccf-app.initialUserPasswordSource" .) -}}
{{- $names = append $names "initial admin user password" -}}
{{- $missing = append $missing "- initial admin user password: api.user.existingSecret (+ api.user.passwordKey), api.user.externalSecret.enabled=true (External Secrets Operator), api.user.password, or devSecrets.seed (development only)" -}}
{{- end -}}
{{- if and .Values.dex.enabled (not (include "ccf-app.dexClientSecretSource" .)) -}}
{{- $names = append $names "Dex client secret" -}}
{{- $missing = append $missing "- Dex client secret: dex.clientSecret.existingSecret (with createSecret: false), dex.clientSecret.externalSecret.enabled=true (External Secrets Operator), dex.clientSecret.value, or devSecrets.seed (development only)" -}}
{{- end -}}
{{- if $missing -}}
{{- fail (printf "no source for: %s. The chart does not generate credentials (generated values are not stable under helm template / Argo CD). Set:\n%s\nSee the chart README, section Credentials." (join ", " $names) (join "\n" $missing)) -}}
{{- end -}}
{{- end }}

{{/*
An ExternalSecret that External Secrets Operator fills from a Password generator, created once.
Usage: include "ccf-app.passwordExternalSecret" (dict "root" . "name" <secret name> "key" <secret key> "component" <label component>)
*/}}
{{- define "ccf-app.passwordExternalSecret" -}}
{{- $root := .root -}}
{{- $eso := default (dict) $root.Values.externalSecrets -}}
apiVersion: {{ default "generators.external-secrets.io/v1alpha1" $eso.generatorApiVersion }}
kind: Password
metadata:
  name: {{ .name }}
  labels:
    {{- include "ccf-app.labels" $root | nindent 4 }}
spec:
  {{- toYaml (default (dict "length" 32 "digits" 6 "symbols" 0 "noUpper" false "allowRepeat" true) $eso.passwordGenerator) | nindent 2 }}
---
apiVersion: {{ default "external-secrets.io/v1" $eso.apiVersion }}
kind: ExternalSecret
metadata:
  name: {{ .name }}
  labels:
    {{- include "ccf-app.labels" $root | nindent 4 }}
spec:
  refreshPolicy: {{ default "CreatedOnce" $eso.refreshPolicy }}
  target:
    name: {{ .name }}
    creationPolicy: Owner
  dataFrom:
    - sourceRef:
        generatorRef:
          apiVersion: {{ default "generators.external-secrets.io/v1alpha1" $eso.generatorApiVersion }}
          kind: Password
          name: {{ .name }}
      rewrite:
        - regexp:
            source: "^password$"
            target: {{ .key | quote }}
{{- end }}
