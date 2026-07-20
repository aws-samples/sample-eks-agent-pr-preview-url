# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0
{{/* Common naming + label helpers for a Preview Environment. */}}

{{- define "preview-env.name" -}}
web
{{- end -}}

{{- define "preview-env.prSlug" -}}
pr-{{ .Values.prNumber }}
{{- end -}}

{{/*
The host used by the Ingress.
  host mode -> pr-<n>.<baseDomain>
  path mode -> .Values.routing.pathHost (may be empty => match any host)
*/}}
{{- define "preview-env.host" -}}
{{- if eq .Values.routing.mode "host" -}}
{{ include "preview-env.prSlug" . }}.{{ .Values.routing.baseDomain }}
{{- else -}}
{{ .Values.routing.pathHost }}
{{- end -}}
{{- end -}}

{{/* The basePath baked into the image — only set in path mode. */}}
{{- define "preview-env.basePath" -}}
{{- if eq .Values.routing.mode "path" -}}/{{ include "preview-env.prSlug" . }}{{- end -}}
{{- end -}}

{{/*
Per-commit immutable host (host mode only): pr-<n>-<shortSha>.<baseDomain>.
The commit-pinned "view this exact deployment" analog. Empty unless host mode AND a
commitSha is provided — in path mode a servable commit URL collides with the
baked basePath, so the platform falls back to the GitHub commit link.
*/}}
{{- define "preview-env.commitHost" -}}
{{- if and (eq .Values.routing.mode "host") .Values.commitSha -}}
{{ include "preview-env.prSlug" . }}-{{ .Values.commitSha }}.{{ .Values.routing.baseDomain }}
{{- end -}}
{{- end -}}

{{/*
Label domain is a FIXED internal constant (pr-preview), not derived from the
AWS-facing project name. Deploy, selection, and teardown all key on it, so it
must be identical across the chart, scripts, and workflows — keeping it fixed
removes any rename-drift hazard when a user changes their project name.
*/}}
{{- define "preview-env.labels" -}}
app.kubernetes.io/name: {{ include "preview-env.name" . }}
app.kubernetes.io/managed-by: pr-preview
app.kubernetes.io/part-of: preview-platform
preview.pr-preview/pr-number: {{ .Values.prNumber | quote }}
{{- range $k, $v := .Values.commonLabels }}
{{ $k }}: {{ $v | quote }}
{{- end }}
{{- end -}}

{{- define "preview-env.selectorLabels" -}}
app.kubernetes.io/name: {{ include "preview-env.name" . }}
preview.pr-preview/pr-number: {{ .Values.prNumber | quote }}
{{- end -}}