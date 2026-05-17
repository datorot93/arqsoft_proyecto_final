#!/usr/bin/env bash
# F4 — Build de las 4 imágenes OCI con Jib y carga al daemon Docker local.
#
# Jib requiere una registry accesible. En kind local, usamos jib.dockerBuild (tarea
# alternativa que escribe directamente al Docker daemon) y luego kind load docker-image
# para inyectarla en los nodos del cluster.
#
# Para publicar a una registry remota (kind-registry:5000 o OCIR), exportar:
#   export REGISTRY=kind-registry:5000
# y ejecutar:
#   ./gradlew :cdt-pais:jib :acl:jib :outbox-dispatcher:jib :core-stub:jib
#
# Prerrequisitos:
#   - Java 21 LTS disponible en PATH
#   - Gradle wrapper disponible (./gradlew)
#   - Docker daemon corriendo (para jibDockerBuild)
#   - kind cluster corriendo (para kind load docker-image)

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SERVICES_DIR="$ROOT_DIR/services"
CLUSTER_NAME="${KIND_CLUSTER_NAME:-linea-verde}"

source "$ROOT_DIR/versions.env"

echo "=== F4: Build de servicios Spring Boot con Jib ==="
echo "    Java: $(java -version 2>&1 | head -1)"
echo "    Cluster: $CLUSTER_NAME"
echo ""

cd "$SERVICES_DIR"

# Opción 1: Si hay registry local de kind corriendo (solo kind-registry:5000, no localhost)
if nc -z kind-registry 5000 2>/dev/null; then
  echo "Registry local detectada. Publicando con jib..."
  export REGISTRY="${REGISTRY:-kind-registry:5000}"
  ./gradlew :cdt-pais:jib :acl:jib :outbox-dispatcher:jib :core-stub:jib \
    --stacktrace 2>&1 | tail -30
  echo "Imágenes publicadas a $REGISTRY/linea-verde/{cdt-pais,acl,outbox-dispatcher,core-stub}"

# Opción 2: Sin registry — cargar al Docker daemon y luego a kind
else
  echo "Sin registry local. Usando jibDockerBuild + kind load docker-image..."
  ./gradlew :cdt-pais:jibDockerBuild :acl:jibDockerBuild \
            :outbox-dispatcher:jibDockerBuild :core-stub:jibDockerBuild \
            --stacktrace 2>&1 | tail -30

  VERSION="0.1.0-SNAPSHOT"
  REGISTRY_PREFIX="kind-registry:5000/linea-verde"

  for svc in cdt-pais acl outbox-dispatcher core-stub; do
    echo "Cargando $svc al cluster kind..."
    kind load docker-image "${REGISTRY_PREFIX}/${svc}:latest" \
         --name "$CLUSTER_NAME" 2>/dev/null || \
    kind load docker-image "${REGISTRY_PREFIX}/${svc}:${VERSION}" \
         --name "$CLUSTER_NAME" 2>/dev/null || true
  done
fi

echo ""
echo "=== Build completado ==="
echo "Próximo paso: bash scripts/services_deploy.sh"
