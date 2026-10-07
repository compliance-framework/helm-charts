{{/*
DEPRECATED generated credentials: the chart's behaviour before 0.9.0, kept as the default so a
plain `helm install` / unchanged upgrade works exactly as before. These are the ONLY helpers that
may call lookup or generate random values (ci/argocd/check.sh enforces it). They are not
GitOps-safe: under `helm template` (Argo CD, Flux) lookup returns nothing, so every render
generates new passwords, and the JWT key never used lookup, so it is new on every render. They
will be removed in a future release; NOTES print a DEPRECATED notice whenever one is used.
*/}}

{{/* PostgreSQL password: reuse <fullname>-psql POSTGRES_PASSWORD if the Secret exists, else random. */}}
{{- define "ccf-app.deprecated.psqlPasswordB64" -}}
{{- $existing := lookup "v1" "Secret" .Release.Namespace (printf "%s-psql" (include "ccf-app.fullname" .)) -}}
{{- if and $existing (index (default (dict) $existing.data) "POSTGRES_PASSWORD") -}}
{{- index $existing.data "POSTGRES_PASSWORD" -}}
{{- else -}}
{{- randAlphaNum 32 | b64enc -}}
{{- end -}}
{{- end -}}

{{/* Initial user password: reuse <fullname>-initial-user-password if it exists, else random. */}}
{{- define "ccf-app.deprecated.initialUserPasswordB64" -}}
{{- $existing := lookup "v1" "Secret" .Release.Namespace (printf "%s-initial-user-password" (include "ccf-app.fullname" .)) -}}
{{- if and $existing (index (default (dict) $existing.data) "password") -}}
{{- index $existing.data "password" -}}
{{- else -}}
{{- randAlphaNum 12 | b64enc -}}
{{- end -}}
{{- end -}}

{{/* Dex client secret: reuse the key in <fullname>-dex if it exists, else random. */}}
{{- define "ccf-app.deprecated.dexClientSecretB64" -}}
{{- $key := include "ccf-app.dexClientSecretKey" . -}}
{{- $existing := lookup "v1" "Secret" .Release.Namespace (printf "%s-dex" (include "ccf-app.fullname" .)) -}}
{{- if and $existing (index (default (dict) $existing.data) $key) -}}
{{- index $existing.data $key -}}
{{- else -}}
{{- randAlphaNum 32 | b64enc -}}
{{- end -}}
{{- end -}}

{{/* JWT private key (api.jwt.source=generated): a new key on every render, no lookup, as before. */}}
{{- define "ccf-app.deprecated.jwtPrivateKeyB64" -}}
{{- genPrivateKey "rsa" | b64enc -}}
{{- end -}}
