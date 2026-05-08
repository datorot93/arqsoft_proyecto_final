# Makefile maestro del experimento Línea Verde.
# Documentación: docs/experimento_asr.md  ·  Specs: .claude/specs/

SHELL := /usr/bin/env bash
.DEFAULT_GOAL := help

##@ F1 — Bootstrap del cluster

up: ## Levanta el cluster + metrics-server + namespaces + NetworkPolicies + quotas (idempotente)
	@bash scripts/bootstrap_cluster.sh

down: ## Elimina el cluster kind
	@bash scripts/teardown_cluster.sh

nuke: down ## Alias de down (compatibilidad con el spec)

##@ F2 — Plataforma de datos y mensajería

platform-up: ## Despliega CNPG + 3 Postgres + Redpanda + Apicurio + Kong DB-less
	@bash scripts/platform_bootstrap.sh

platform-down: ## Desmonta F2 (deja F1 intacta)
	@bash scripts/platform_teardown.sh

##@ Pruebas (gates por fase)

test-f1: ## Ejecuta los 9 tests del gate F1
	@bash tests/f1/run-gates.sh

test-f2: ## Ejecuta los 11 tests del gate F2
	@bash tests/f2/run-gates.sh

##@ Validación estática

validate-manifests: ## Valida los manifiestos K8s con --dry-run=client (no requiere cluster)
	@for f in infra/k8s/00-namespaces.yaml infra/k8s/01-network-policies/*.yaml infra/k8s/02-quotas/*.yaml; do \
		echo "→ $$f"; \
		kubectl apply --dry-run=client -f $$f >/dev/null && echo "  ✓ válido" || exit 1; \
	done
	@echo "✓ Todos los manifiestos validados"

validate-versions: ## Verifica que versions.env coincida con docs/experimento_asr.md §6.4.10
	@echo "TODO en F7: scripts/check_versions.py"

##@ Utilidades

clean: ## Borra artefactos generados localmente (mantiene fuentes)
	@rm -rf .tmp build/ runs/results/

help: ## Muestra esta ayuda
	@awk 'BEGIN {FS = ":.*##"; printf "\n\033[1mMakefile · Banco Z – Línea Verde\033[0m\n\nUso:\n  make \033[36m<target>\033[0m\n"} /^[a-zA-Z_0-9-]+:.*?##/ { printf "  \033[36m%-22s\033[0m %s\n", $$1, $$2 } /^##@/ { printf "\n\033[1m%s\033[0m\n", substr($$0, 5) }' $(MAKEFILE_LIST)

.PHONY: up down nuke platform-up platform-down test-f1 test-f2 validate-manifests validate-versions clean help
