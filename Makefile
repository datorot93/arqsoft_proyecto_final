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

##@ F3 — Observabilidad transversal

observability-up: ## Instala kube-prometheus-stack + Tempo + Loki + OTel Collector + dashboards
	@bash scripts/observability_bootstrap.sh

observability-down: ## Desmonta F3 (deja F1 y F2 intactas)
	@bash scripts/observability_teardown.sh

##@ F4 — Servicios de aplicación Spring Boot

services-build: ## Compila las 4 imágenes con Jib (carga a Docker daemon local)
	@bash scripts/services_build.sh

services-deploy: ## Aplica deployments + HPA + ServiceMonitors (asume imágenes cargadas)
	@bash scripts/services_deploy.sh

services-down: ## Borra los deployments F4 (deja F1+F2+F3 intactos)
	@bash scripts/services_teardown.sh

##@ F5 — Generador de carga estocástico k6

load-build: ## Bundle de scripts JS + build de imagen k6 + kind load
	@for s in load/scenarios/warmup.js load/scenarios/baseline_asr1.js load/scenarios/peak_asr2.js; do \
		out=load/dist/$$(basename $$s .js).bundled.js; \
		python3 scripts/bundle_k6.py $$s $$out; \
	done
	@docker build -t kind-registry:5000/linea-verde/k6-loader:latest -f load/Dockerfile.k6 .
	@kind load docker-image kind-registry:5000/linea-verde/k6-loader:latest --name $${KIND_CLUSTER_NAME:-linea-verde}
	@echo "✓ Imagen k6-loader:latest disponible en cluster"

load-deploy: ## Despliega k6-operator + ConfigMaps de scripts + RBAC del namespace carga
	@bash scripts/load_bootstrap.sh

load-warmup: ## Lanza el K6 TestRun de warmup (5 min, 2 r/s)
	@kubectl apply -f infra/k8s/carga/k6-warmup.yaml

load-baseline: ## Lanza el K6 TestRun de baseline_asr1 (15 min, 0.2 r/s)
	@kubectl apply -f infra/k8s/carga/k6-baseline.yaml

load-peak: ## Lanza el K6 TestRun de peak_asr2 (20 min, NHPP+MMPP+Dirichlet)
	@kubectl apply -f infra/k8s/carga/k6-peak.yaml

load-down: ## Elimina TestRuns F5 (deja k6-operator + ConfigMaps)
	@kubectl delete testrun -n carga --all --ignore-not-found
	@kubectl delete pod -n carga --all --ignore-not-found
	@echo "✓ TestRuns y pods F5 eliminados"

validate-load-model: ## Corre los 6 tests JS standalone del modelo estocástico (NHPP+MMPP+Dirichlet+Lognormal+Repro)
	@cd load && \
		node test/validate_nhpp.js --samples 10000 --lambda 5 && \
		node test/integrate_lambda.js && \
		node test/analyze_mmpp.js && \
		node test/analyze_dirichlet.js && \
		node test/measure_payload.js && \
		H1=$$(node test/repro_hash.js --seed 42 2>/dev/null); \
		H2=$$(node test/repro_hash.js --seed 42 2>/dev/null); \
		[ "$$H1" = "$$H2" ] && echo "  ✓ repro_hash determinista (sha256=$${H1:0:16}...)" || (echo "✗ repro_hash NO determinista" && exit 1)
	@echo "✓ Modelo estadístico validado"

##@ Pruebas (gates por fase)

test-f1: ## Ejecuta los 9 tests del gate F1
	@bash tests/f1/run-gates.sh

test-f2: ## Ejecuta los 11 tests del gate F2
	@bash tests/f2/run-gates.sh

test-f3: ## Ejecuta los 10 tests del gate F3
	@bash tests/f3/run-gates.sh

test-f4: ## Ejecuta los 13 tests del gate F4
	@bash tests/f4/run-gates.sh

test-f5: ## Ejecuta los 12 tests del gate F5
	@bash tests/f5/run-gates.sh

##@ F6 — Ejecución y análisis (veredicto AC-*)

f6-round: ## Lanza UNA ronda (warmup+baseline+peak). Variables: SEED=42 MODE=smoke|scaled|full
	@python3 runs/run_round.py --seed $${SEED:-42} --$${MODE:-scaled}

f6-rounds: ## Lanza N=5 rondas con seeds 42..46 (mode=$${MODE:-scaled})
	@for s in 42 43 44 45 46; do \
		echo "=== ronda seed=$$s ==="; \
		python3 runs/run_round.py --seed $$s --$${MODE:-scaled} || exit 1; \
	done
	@$(MAKE) f6-aggregate

f6-aggregate: ## Genera aggregate.html sobre runs/results/r* (idempotente)
	@python3 runs/aggregate_results.py runs/results/r*

f6-report: ## Abre el último report.html en navegador (xdg-open / wsl-open)
	@latest=$$(ls -dt runs/results/r*-s*-* 2>/dev/null | head -1); \
	if [ -z "$$latest" ]; then echo "sin rondas"; exit 1; fi; \
	report="$$latest/report.html"; \
	echo "→ $$report"; \
	if command -v wslview >/dev/null; then wslview "$$report"; \
	elif command -v xdg-open >/dev/null; then xdg-open "$$report"; \
	else echo "abrir manualmente: $$report"; fi

test-f6: ## Ejecuta los 10 tests del gate F6 (inspección de la última ronda)
	@bash tests/f6/run-gates.sh

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

.PHONY: up down nuke platform-up platform-down observability-up observability-down \
        services-build services-deploy services-down \
        load-build load-deploy load-warmup load-baseline load-peak load-down validate-load-model \
        test-f1 test-f2 test-f3 test-f4 test-f5 \
        validate-manifests validate-versions clean help
