# examples/outputs.tf — Outputs principales de la composición completa

output "compartment_id" {
  description = "OCID del compartment creado para Línea Verde."
  value       = module.iam.compartment_id
}

output "vcn_id" {
  description = "OCID de la VCN."
  value       = module.networking.vcn_id
}

output "oke_kubeconfig" {
  description = "Comando para obtener el kubeconfig del cluster OKE."
  value       = module.oke.oke_kubeconfig
}

output "db_connection_string" {
  description = "JDBC connection strings de los 3 shards de base de datos (pe/mx/co)."
  value = {
    pe = module.db_pe.db_connection_string
    mx = module.db_mx.db_connection_string
    co = module.db_co.db_connection_string
  }
  sensitive = false
}

output "streaming_bootstrap" {
  description = "Kafka bootstrap server de OCI Streaming."
  value       = module.streaming.streaming_bootstrap
}

output "ocir_endpoint" {
  description = "Endpoint OCIR para docker login."
  value       = module.registry.ocir_endpoint
}

output "ocir_image_base_path" {
  description = "Path base de imágenes en OCIR."
  value       = module.registry.image_base_path
}

output "db_engine_used" {
  description = "Motor de base de datos efectivamente aprovisionado."
  value       = var.db_engine
}
