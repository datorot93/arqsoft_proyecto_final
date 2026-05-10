# streaming/main.tf
# OCI Streaming: Stream pool + tópico cdt.eventos.
# Sustituto gestionado de Redpanda en producción (Kafka API compatible).
# Banco Z – Línea Verde — ref: docs/experimento_asr.md §6.4.11, despliegue.png

terraform {
  required_version = "~> 1.9.6"
  required_providers {
    oci = {
      source  = "oracle/oci"
      version = "~> 6.10"
    }
  }
}

# ── Stream Pool ───────────────────────────────────────────────────────────────

resource "oci_streaming_stream_pool" "lv_pool" {
  compartment_id = var.compartment_ocid
  name           = "${var.prefix}-stream-pool"

  kafka_settings {
    auto_create_topics_enable = false
    log_retention_hours       = var.log_retention_hours
    num_partitions            = var.default_partitions
  }

  freeform_tags = var.tags
}

# ── Tópico cdt.eventos ────────────────────────────────────────────────────────

resource "oci_streaming_stream" "cdt_eventos" {
  compartment_id   = var.compartment_ocid
  name             = "cdt.eventos"
  partitions       = var.cdt_eventos_partitions
  retention_in_hours = var.log_retention_hours
  stream_pool_id   = oci_streaming_stream_pool.lv_pool.id

  freeform_tags = merge(var.tags, { topico = "cdt.eventos" })
}

# ── Tópicos adicionales del modelo (credito.eventos, saldo.cambios) ───────────

resource "oci_streaming_stream" "credito_eventos" {
  compartment_id   = var.compartment_ocid
  name             = "credito.eventos"
  partitions       = var.default_partitions
  retention_in_hours = var.log_retention_hours
  stream_pool_id   = oci_streaming_stream_pool.lv_pool.id

  freeform_tags = merge(var.tags, { topico = "credito.eventos" })
}

resource "oci_streaming_stream" "saldo_cambios" {
  compartment_id   = var.compartment_ocid
  name             = "saldo.cambios"
  partitions       = var.default_partitions
  retention_in_hours = var.log_retention_hours
  stream_pool_id   = oci_streaming_stream_pool.lv_pool.id

  freeform_tags = merge(var.tags, { topico = "saldo.cambios" })
}
