# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0
# pr-preview — convenience targets
.PHONY: help install test e2e kind-up kind-down preview-up preview-down synth lint

help:
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | awk 'BEGIN{FS=":.*?## "}{printf "  \033[36m%-14s\033[0m %s\n",$$1,$$2}'

install: ## Install all workspace deps (app, skill, infra)
	cd app && npm install
	cd skills/preview-iterate && npm install
	cd infra && npm install

test: ## Run the full non-cluster suite (unit + render + typecheck + e2e)
	bash scripts/test-all.sh

e2e: ## Run the native end-to-end suite only
	node e2e/native-e2e.mjs

lint: ## Lint what CI lints: workflows (actionlint) + chart (helm lint)
	@command -v actionlint >/dev/null 2>&1 && actionlint || echo "actionlint not installed — skipping (CI runs it)"
	helm lint charts/preview-env

synth: ## CDK synth (verify infra compiles)
	cd infra && JSII_SILENCE_WARNING_UNTESTED_NODE_VERSION=1 npx cdk synth --quiet

kind-up: ## Create the local kind cluster + ingress-nginx
	bash scripts/kind-up.sh

kind-down: ## Delete the local kind cluster
	kind delete cluster --name pr-preview

preview-up: ## Deploy a preview on kind: make preview-up PR=42 SHA=abc1234
	bash scripts/preview-local.sh up $(PR) $(SHA) $(or $(DELAY),0)

preview-down: ## Tear down a preview: make preview-down PR=42
	bash scripts/preview-local.sh down $(PR)