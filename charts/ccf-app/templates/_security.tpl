{{/*
Security contexts. Every workload resolves its pod and container securityContext as:
  the component's own value (api.*, ui.*, dex.*, database.local.*, pgadmin4.*), else
  the global podSecurityContext / securityContext, else
  the chart default below (non-root, read-only root filesystem, no privilege escalation,
  no capabilities, seccomp RuntimeDefault), with emptyDirs for every path the image writes.
So installs that set any of these keep exactly what they set.
Usage: include "ccf-app.securityContext" (dict "own" <value> "global" <value> "default" <dict>)
*/}}
{{- define "ccf-app.securityContext" -}}
{{- $ctx := coalesce .own .global -}}
{{- if not $ctx -}}
{{- $ctx = .default -}}
{{- end -}}
{{- toYaml $ctx -}}
{{- end }}

{{/* Container defaults shared by every workload; the user and group are set per pod. */}}
{{- define "ccf-app.hardenedContainerDefaults" -}}
runAsNonRoot: true
readOnlyRootFilesystem: true
allowPrivilegeEscalation: false
capabilities:
  drop:
    - ALL
seccompProfile:
  type: RuntimeDefault
{{- end }}

{{/* Pod defaults for a uid/gid: Pod Security "restricted", no sysctls.
Usage: include "ccf-app.hardenedPodDefaults" (dict "uid" 101 "gid" 101) */}}
{{- define "ccf-app.hardenedPodDefaults" -}}
runAsNonRoot: true
runAsUser: {{ .uid }}
runAsGroup: {{ .gid }}
fsGroup: {{ .gid }}
seccompProfile:
  type: RuntimeDefault
{{- end }}

{{/*
API: the image (distroless base-debian12) has no USER. Every container of the pod runs as
65532: the API, migrate-db and create-user (they run /api), wait-for-postgres (pg_isready) and
generate-public-key (alpine/openssl, writes only to the shared publickey emptyDir).
*/}}
{{- define "ccf-app.apiPodSecurityContext" -}}
{{- include "ccf-app.securityContext" (dict "own" .Values.api.podSecurityContext "global" .Values.podSecurityContext "default" (include "ccf-app.hardenedPodDefaults" (dict "uid" 65532 "gid" 65532) | fromYaml)) -}}
{{- end }}

{{- define "ccf-app.apiSecurityContext" -}}
{{- $default := merge (dict "runAsUser" 65532 "runAsGroup" 65532) (include "ccf-app.hardenedContainerDefaults" . | fromYaml) -}}
{{- include "ccf-app.securityContext" (dict "own" .Values.api.securityContext "global" .Values.securityContext "default" $default) -}}
{{- end }}

{{/*
UI: nginx from the ui image, as its nginx user (101), listening on the unprivileged
ui.containerPort (8080) through the chart's server configuration (configmap_ui_nginx.yaml)
instead of the image's port-80 one. No sysctl. nginx writes /var/cache/nginx, its pid file in
/run, and /tmp: all emptyDirs.
*/}}
{{- define "ccf-app.uiPodSecurityContext" -}}
{{- include "ccf-app.securityContext" (dict "own" .Values.ui.podSecurityContext "global" .Values.podSecurityContext "default" (include "ccf-app.hardenedPodDefaults" (dict "uid" 101 "gid" 101) | fromYaml)) -}}
{{- end }}

{{- define "ccf-app.uiSecurityContext" -}}
{{- include "ccf-app.securityContext" (dict "own" .Values.ui.securityContext "global" .Values.securityContext "default" (include "ccf-app.hardenedContainerDefaults" . | fromYaml)) -}}
{{- end }}

{{/* Dex: the image's own user (1001). With in-memory storage dex writes only to /tmp. */}}
{{- define "ccf-app.dexPodSecurityContext" -}}
{{- include "ccf-app.securityContext" (dict "own" .Values.dex.podSecurityContext "global" .Values.podSecurityContext "default" (include "ccf-app.hardenedPodDefaults" (dict "uid" 1001 "gid" 1001) | fromYaml)) -}}
{{- end }}

{{- define "ccf-app.dexSecurityContext" -}}
{{- include "ccf-app.securityContext" (dict "own" .Values.dex.securityContext "global" .Values.securityContext "default" (include "ccf-app.hardenedContainerDefaults" . | fromYaml)) -}}
{{- end }}

{{/*
Bundled PostgreSQL: the image's postgres user (999), writing to its data volume (a dynamically
provisioned PVC by default; fsGroup 999 makes it group-writable without any root step), the
socket directory /var/run/postgresql and /tmp (emptyDirs).
*/}}
{{- define "ccf-app.psqlPodSecurityContext" -}}
{{- $default := merge (dict "fsGroupChangePolicy" "OnRootMismatch") (include "ccf-app.hardenedPodDefaults" (dict "uid" 999 "gid" 999) | fromYaml) -}}
{{- include "ccf-app.securityContext" (dict "own" .Values.database.local.podSecurityContext "global" .Values.podSecurityContext "default" $default) -}}
{{- end }}

{{- define "ccf-app.psqlSecurityContext" -}}
{{- include "ccf-app.securityContext" (dict "own" .Values.database.local.securityContext "global" .Values.securityContext "default" (include "ccf-app.hardenedContainerDefaults" . | fromYaml)) -}}
{{- end }}

{{/*
pgAdmin 4: the image's pgadmin user (5050). It listens on pgadmin4.containerPort (8080, an
unprivileged port; the image falls back to 8080 anyway when it cannot gain the bind capability)
and writes its config_distro.py into /var/lib/pgadmin instead of /pgadmin4, so the root
filesystem stays read-only. /var/lib/pgadmin, /run/pgadmin and /tmp are emptyDirs.
*/}}
{{- define "ccf-app.pgadmin4PodSecurityContext" -}}
{{- include "ccf-app.securityContext" (dict "own" .Values.pgadmin4.podSecurityContext "global" .Values.podSecurityContext "default" (include "ccf-app.hardenedPodDefaults" (dict "uid" 5050 "gid" 5050) | fromYaml)) -}}
{{- end }}

{{- define "ccf-app.pgadmin4SecurityContext" -}}
{{- include "ccf-app.securityContext" (dict "own" .Values.pgadmin4.securityContext "global" .Values.securityContext "default" (include "ccf-app.hardenedContainerDefaults" . | fromYaml)) -}}
{{- end }}

{{/* helm test pod: busybox wget as nobody (65534). */}}
{{- define "ccf-app.testPodSecurityContext" -}}
{{- include "ccf-app.hardenedPodDefaults" (dict "uid" 65534 "gid" 65534) -}}
{{- end }}
