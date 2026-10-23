{{/*
Labels for every resource of a component.
Usage: include "aspecta.labels" (dict "root" $ "component" "backend")
*/}}
{{- define "aspecta.labels" -}}
helm.sh/chart: {{ printf "%s-%s" .root.Chart.Name .root.Chart.Version | replace "+" "_" }}
app.kubernetes.io/managed-by: {{ .root.Release.Service }}
app.kubernetes.io/part-of: aspecta
app.kubernetes.io/version: {{ .root.Chart.AppVersion | quote }}
{{ include "aspecta.selectorLabels" . }}
{{- end }}

{{/*
Selector labels; also the only labels on pod templates, so a chart version bump does not restart pods.
*/}}
{{- define "aspecta.selectorLabels" -}}
app.kubernetes.io/name: {{ .component }}
app.kubernetes.io/instance: {{ .root.Release.Name }}
{{- end }}
