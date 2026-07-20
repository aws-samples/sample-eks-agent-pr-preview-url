#!/usr/bin/env bash
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0
# drop-schema.sh — DROP the per-PR Postgres schema pr_<n> on teardown
# (closing the schema-isolation gap). Runs a short-lived in-cluster Job using the app
# image (it has `pg`) and the namespace's ESO-synced DB secret, so no DB
# credentials ever touch CI. Best-effort: never blocks teardown.
#
# Usage: drop-schema.sh <pr-number> [namespace] [image]
set -uo pipefail
PR="${1:?pr number required}"
NS="${2:-pr-$PR}"
IMAGE="${3:-${PREVIEW_IMAGE:-}}"
SCHEMA="pr_${PR}"
JOB="drop-schema-${PR}"

# If the namespace is already gone, nothing to do.
kubectl get ns "$NS" >/dev/null 2>&1 || { echo "[drop-schema] ns $NS gone; nothing to drop"; exit 0; }

# Resolve an image: prefer the running deployment's image so we don't hardcode a tag.
if [ -z "$IMAGE" ]; then
  IMAGE="$(kubectl get deploy web -n "$NS" -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null || true)"
fi
[ -n "$IMAGE" ] || { echo "[drop-schema] no image resolvable; skipping schema drop"; exit 0; }

# The DB secret synced by ESO into this namespace (chart names it web-db).
if ! kubectl get secret web-db -n "$NS" >/dev/null 2>&1; then
  echo "[drop-schema] no web-db secret in $NS; DB likely unconfigured; skipping"; exit 0
fi

echo "[drop-schema] dropping schema $SCHEMA via Job/$JOB in $NS"
kubectl delete job "$JOB" -n "$NS" --ignore-not-found >/dev/null 2>&1 || true
cat <<YAML | kubectl apply -f - >/dev/null 2>&1
apiVersion: batch/v1
kind: Job
metadata:
  name: ${JOB}
  namespace: ${NS}
spec:
  backoffLimit: 1
  ttlSecondsAfterFinished: 120
  template:
    spec:
      restartPolicy: Never
      securityContext: { runAsNonRoot: true, runAsUser: 1000, runAsGroup: 1000 }
      containers:
        - name: drop
          image: ${IMAGE}
          command: ["node","-e"]
          args:
            - |
              const {Client}=require('pg');
              const url=process.env.DATABASE_URL;
              if(!url){console.log('no DATABASE_URL; skip');process.exit(0);}
              const s='${SCHEMA}'.replace(/[^a-z0-9_]/g,'_');
              (async()=>{const c=new Client({connectionString:url,connectionTimeoutMillis:5000});
                await c.connect();await c.query('DROP SCHEMA IF EXISTS "'+s+'" CASCADE');
                console.log('dropped schema',s);await c.end();})()
                .catch(e=>{console.error('drop failed (non-fatal):',e.message);process.exit(0);});
          env:
            - name: DATABASE_URL
              valueFrom: { secretKeyRef: { name: web-db, key: DATABASE_URL } }
YAML
# Wait briefly; never fail teardown if the drop is slow/unavailable.
kubectl wait --for=condition=complete "job/${JOB}" -n "$NS" --timeout=60s >/dev/null 2>&1 \
  && echo "[drop-schema] $SCHEMA dropped" \
  || echo "[drop-schema] drop job did not confirm in time (non-fatal)"
