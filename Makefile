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

##@ F7 — Reproducibilidad (CI/CD + IaC OCI)

experiment: ## Levanta stack completo y corre 1 ronda smoke (idempotente si cluster ya existe)
	@kind get clusters 2>/dev/null | grep -q "$${KIND_CLUSTER_NAME:-linea-verde}" || make up
	@bash -c 'kind get clusters 2>/dev/null | grep -q "$${KIND_CLUSTER_NAME:-linea-verde}" && echo "cluster ya existe, skipping platform-up..." || make platform-up' || make platform-up
	@make observability-up || true
	@make services-build
	@make services-deploy
	@make load-build
	@make load-deploy
	@python3 runs/run_round.py --seed $${SEED:-42} --$${MODE:-smoke}
	@echo "Ronda completada. Ver reporte: make report"

report: ## Genera reporte agregado y lo abre (requiere rondas previas en runs/results/)
	@python3 runs/aggregate_results.py runs/results/r* 2>/dev/null || echo "Sin rondas para agregar"
	@latest=$$(ls -dt runs/results/r*-s*-* 2>/dev/null | head -1); \
	if [ -z "$$latest" ]; then echo "Sin rondas disponibles"; exit 1; fi; \
	report="$$latest/report.html"; \
	echo "→ $$report"; \
	if command -v wslview >/dev/null; then wslview "$$report"; \
	elif command -v xdg-open >/dev/null; then xdg-open "$$report"; \
	else echo "Abrir manualmente: $$report"; fi

tf-validate: ## terraform validate + tflint en todos los módulos infra/terraform/
	@echo "=== terraform validate ==="
	@for d in infra/terraform/networking infra/terraform/iam infra/terraform/oke \
	           infra/terraform/db infra/terraform/streaming infra/terraform/registry \
	           infra/terraform/examples; do \
		echo "→ $$d"; \
		terraform -chdir="$$d" init -backend=false -no-color >/dev/null 2>&1 && \
		terraform -chdir="$$d" validate -no-color && echo "  ✓ válido" || echo "  ✗ FALLO"; \
	done
	@echo ""
	@echo "=== tflint ==="
	@if command -v tflint >/dev/null 2>&1; then \
		tflint --recursive --config infra/terraform/.tflint.hcl; \
	else \
		echo "tflint no instalado — instalar: https://github.com/terraform-linters/tflint"; \
	fi

tf-plan: ## Lanza terraform plan vía GitHub Actions (requiere credenciales OCI en secrets)
	@echo "Para lanzar el plan en CI: gh workflow run terraform-plan.yaml"
	@echo "Para validar localmente sin credenciales: make tf-validate"
	@if command -v gh >/dev/null 2>&1; then \
		echo "Disponible: gh workflow run terraform-plan.yaml"; \
	fi

tf-apply: ## Lanza terraform apply vía workflow_dispatch en GitHub Actions
	@if command -v gh >/dev/null 2>&1; then \
		gh workflow run terraform-apply.yaml \
			-f action=apply \
			-f db_engine=$${DB_ENGINE:-postgres} \
			-f ttl_hours=$${TTL_HOURS:-24} \
			-f skip_destroy=$${SKIP_DESTROY:-false}; \
	else \
		echo "ERROR: gh CLI no instalado. Instalar: https://cli.github.com/"; \
		exit 1; \
	fi

helm-lint: ## helm lint del chart lv-experiment
	@helm lint infra/helm/lv-experiment

check-versions: ## Verifica que versions.env coincida con docs/experimento_asr.md §6.4.10
	@python3 scripts/check_versions.py docs/experimento_asr.md versions.env

test-f7: ## Ejecuta los 12 tests del gate F7 (CI/CD + IaC + Helm)
	@bash tests/f7/run-gates.sh

##@ F8 — Integración E2E + README

# Bootstrap idempotente compartido por e2e-short y e2e-full.
_e2e-bootstrap:
	@kind get clusters 2>/dev/null | grep -q "$${KIND_CLUSTER_NAME:-linea-verde}" || make up
	@bash -c 'kubectl get namespace datos >/dev/null 2>&1 || make platform-up'
	@bash -c 'kubectl get namespace observabilidad >/dev/null 2>&1 || make observability-up'
	@bash -c 'kubectl get deploy -n linea-verde cdt-pais-pe >/dev/null 2>&1 || (make services-build && make services-deploy)'
	@bash -c 'kubectl get deploy -n carga k6-operator >/dev/null 2>&1 || (make load-build && make load-deploy)'

e2e-short: _e2e-bootstrap ## Smoke E2E corto desde estado limpio (≤30 min): up+platform+observ+svc+carga+1 ronda e2e-short
	@echo "=== F8 smoke E2E corto — warmup 2m + baseline 3m + peak 5m ==="
	@echo "NOTA: Smoke test estructural — no autoritativo. Veredicto final: 'make e2e-full'."
	@bash scripts/e2e_short.sh
	@echo "=== e2e-short completado ==="

e2e-full: _e2e-bootstrap ## E2E completo N=5 rondas full (3.5h — requiere CI runner con >=16 GiB RAM)
	@echo "=== F8 E2E completo — N=5 rondas mode=full ==="
	@echo "NOTA: Este target es autoritativo. Requiere CI runner con >=16 GiB RAM."
	@echo "      En local con WSL2 1-nodo se documenta como FAIL ENV (ver tests/f8/VERIFICACION.md)."
	@echo "      Para lanzar en CI: el workflow experiment-nightly.yaml lo ejecuta automáticamente."
	@for s in 42 43 44 45 46; do \
		echo "=== ronda seed=$$s mode=full ==="; \
		python3 runs/run_round.py --seed $$s --full \
			--out runs/results/e2e-full || exit 1; \
	done
	@python3 runs/aggregate_results.py runs/results/e2e-full/r*
	@echo "=== e2e-full completado — ver runs/results/e2e-full/ ==="

validate-readme: ## Valida README.md: secciones, componentes, versiones, enlaces (F8.T-5)
	@python3 scripts/validate_readme.py

test-f8: ## Ejecuta los 12 tests del gate F8 (E2E + README + validadores)
	@bash tests/f8/run-gates.sh

##@ Validación estática

validate-manifests: ## Valida los manifiestos K8s con --dry-run=client (no requiere cluster)
	@for f in infra/k8s/00-namespaces.yaml infra/k8s/01-network-policies/*.yaml infra/k8s/02-quotas/*.yaml; do \
		echo "→ $$f"; \
		kubectl apply --dry-run=client -f $$f >/dev/null && echo "  ✓ válido" || exit 1; \
	done
	@echo "✓ Todos los manifiestos validados"

validate-versions: ## Verifica que versions.env coincida con docs/experimento_asr.md §6.4.10
	@python3 scripts/check_versions.py docs/experimento_asr.md versions.env

##@ Utilidades

clean: ## Borra artefactos generados localmente (mantiene fuentes)
	@rm -rf .tmp build/ runs/results/

help: ## Muestra esta ayuda
	@awk 'BEGIN {FS = ":.*##"; printf "\n\033[1mMakefile · Banco Z – Línea Verde\033[0m\n\nUso:\n  make \033[36m<target>\033[0m\n"} /^[a-zA-Z_0-9-]+:.*?##/ { printf "  \033[36m%-22s\033[0m %s\n", $$1, $$2 } /^##@/ { printf "\n\033[1m%s\033[0m\n", substr($$0, 5) }' $(MAKEFILE_LIST)

.PHONY: up down nuke platform-up platform-down observability-up observability-down \
        services-build services-deploy services-down \
        load-build load-deploy load-warmup load-baseline load-peak load-down validate-load-model \
        test-f1 test-f2 test-f3 test-f4 test-f5 test-f6 \
        experiment report tf-validate tf-plan tf-apply helm-lint check-versions test-f7 \
        _e2e-bootstrap e2e-short e2e-full validate-readme test-f8 \
        validate-manifests validate-versions clean help
