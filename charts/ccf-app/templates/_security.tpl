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

{{/* Pod defaults for a uid/gid. Usage: include "ccf-app.hardenedPodDefaults" (dict "uid" 101 "gid" 101) */}}
{{- define "ccf-app.hardenedPodDefaults" -}}
runAsNonRoot: true
runAsUser: {{ .uid }}
runAsGroup: {{ .gid }}
fsGroup: {{ .gid }}
seccompProfile:
  type: RuntimeDefault
{{- with .sysctls }}
sysctls:
  {{- toYaml . | nindent 2 }}
{{- end }}
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
UI: nginx from the ui image, as its nginx user (101). The image listens on port 80, so the pod
sets the namespaced sysctl net.ipv4.ip_unprivileged_port_start=0 (in the Kubernetes safe set)
instead of changing the UI's nginx configuration. nginx writes /var/cache/nginx, its pid file
in /run, and /tmp: all emptyDirs.
*/}}
{{- define "ccf-app.uiPodSecurityContext" -}}
{{- include "ccf-app.securityContext" (dict "own" .Values.ui.podSecurityContext "global" .Values.podSecurityContext "default" (include "ccf-app.hardenedPodDefaults" (dict "uid" 101 "gid" 101 "sysctls" (list (dict "name" "net.ipv4.ip_unprivileged_port_start" "value" "0"))) | fromYaml)) -}}
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
Bundled PostgreSQL: the image's postgres user (999), writing to the data volume, the socket
directory /var/run/postgresql and /tmp (emptyDirs). The volume-permissions init container is
the one exception: see ccf-app.psqlVolumePermissionsSecurityContext.
*/}}
{{- define "ccf-app.psqlPodSecurityContext" -}}
{{- include "ccf-app.securityContext" (dict "own" .Values.database.local.podSecurityContext "global" .Values.podSecurityContext "default" (include "ccf-app.hardenedPodDefaults" (dict "uid" 999 "gid" 999) | fromYaml)) -}}
{{- end }}

{{- define "ccf-app.psqlSecurityContext" -}}
{{- include "ccf-app.securityContext" (dict "own" .Values.database.local.securityContext "global" .Values.securityContext "default" (include "ccf-app.hardenedContainerDefaults" . | fromYaml)) -}}
{{- end }}

{{/*
The data volume must be owned by uid 999 for postgres (initdb and the server refuse a data
directory they do not own). Volumes without fsGroup support (the chart's default hostPath PV)
are created root-owned, so this init container chowns the volume root once. It runs as root
with only CHOWN and FOWNER, a read-only root filesystem and no privilege escalation.
*/}}
{{- define "ccf-app.psqlVolumePermissionsSecurityContext" -}}
runAsNonRoot: false
runAsUser: 0
runAsGroup: 0
readOnlyRootFilesystem: true
allowPrivilegeEscalation: false
capabilities:
  drop:
    - ALL
  add:
    - CHOWN
    - FOWNER
seccompProfile:
  type: RuntimeDefault
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
