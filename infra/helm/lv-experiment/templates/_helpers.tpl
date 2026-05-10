{{/*
_helpers.tpl — Helpers del chart lv-experiment.
Banco Z – Línea Verde — F7 Reproducibilidad.
*/}}

{{/*
Nombre del chart.
*/}}
{{- define "lv-experiment.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Imagen completa para un servicio dado.
Uso: {{ include "lv-experiment.image" (dict "service" "cdt-pais" "root" .) }}
*/}}
{{- define "lv-experiment.image" -}}
{{- $registry := .root.Values.image.registry -}}
{{- $org := .root.Values.image.organization | default "linea-verde" -}}
{{- $tag := .root.Values.image.tag | default "latest" -}}
{{- printf "%s/%s/%s:%s" $registry $org .service $tag -}}
{{- end }}

{{/*
Labels comunes de selector para un servicio.
*/}}
{{- define "lv-experiment.selectorLabels" -}}
app.kubernetes.io/name: {{ .name }}
app.kubernetes.io/instance: {{ .instance }}
{{- end }}

{{/*
Labels completos para pods y recursos.
*/}}
{{- define "lv-experiment.labels" -}}
helm.sh/chart: {{ .Chart.Name }}-{{ .Chart.Version }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/part-of: linea-verde-experimento
{{- end }}

{{/*
SecurityContext estándar de pods.
*/}}
{{- define "lv-experiment.podSecurityContext" -}}
{{- with .Values.podSecurityContext }}
runAsNonRoot: {{ .runAsNonRoot }}
runAsUser: {{ .runAsUser }}
runAsGroup: {{ .runAsGroup }}
fsGroup: {{ .fsGroup }}
{{- end }}
{{- end }}
