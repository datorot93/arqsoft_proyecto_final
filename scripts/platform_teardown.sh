#!/usr/bin/env bash
# F2 — Teardown idempotente de la plataforma (no borra el cluster, solo F2).

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

say() { printf "\n\033[1;34m==> %s\033[0m\n" "$*"; }

say "Eliminando Kong"
helm uninstall kong -n borde 2>/dev/null || true
kubectl delete -f "$ROOT_DIR/infra/k8s/borde/kong-config.yaml" --ignore-not-found

say "Eliminando Apicurio + Redpanda + tópicos"
kubectl delete -f "$ROOT_DIR/infra/k8s/asincrono/apicurio.yaml" --ignore-not-found
kubectl delete job redpanda-create-topics -n asincrono --ignore-not-found
helm uninstall redpanda -n asincrono 2>/dev/null || true

say "Eliminando NetworkPolicies cross-país"
kubectl delete -f "$ROOT_DIR/infra/k8s/datos/cross-country-netpol.yaml" --ignore-not-found

say "Eliminando 3 clusters Postgres"
for pais in pe mx co; do
  kubectl delete cluster.postgresql.cnpg.io postgres-$pais -n datos --ignore-not-found
done

# El operador y CRDs los dejamos (otros pods pueden depender)
echo
echo "✓ F2 desmontada. F1 (namespaces, etc.) intacta."
echo "  Para borrar también el operador: helm uninstall cnpg-operator -n cnpg-system"
