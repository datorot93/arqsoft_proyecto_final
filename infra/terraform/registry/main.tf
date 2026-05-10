# registry/main.tf
# OCIR (OCI Container Registry) con repositorios por servicio.
# Banco Z – Línea Verde — ref: docs/experimento_asr.md §6.4.9

terraform {
  required_version = "~> 1.9.6"
  required_providers {
    oci = {
      source  = "oracle/oci"
      version = "~> 6.10"
    }
  }
}

# ── Repositorios OCIR por servicio ────────────────────────────────────────────

locals {
  services = ["cdt-pais", "acl", "outbox-dispatcher", "core-stub", "k6-loader"]
}

resource "oci_artifacts_container_repository" "lv_repos" {
  for_each = toset(local.services)

  compartment_id = var.compartment_ocid
  display_name   = "${var.namespace}/lv-experiment/linea-verde/${each.value}"
  is_public      = false

  readme {
    content = "Repositorio OCIR para el servicio ${each.value} del experimento Línea Verde (ASR-1/ASR-2). Banco Z."
    format  = "text/markdown"
  }

  freeform_tags = merge(var.tags, { servicio = each.value })
}
