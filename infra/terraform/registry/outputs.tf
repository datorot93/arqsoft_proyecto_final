# registry/outputs.tf

output "ocir_endpoint" {
  description = "Endpoint base de OCIR para hacer docker login y push/pull de imágenes."
  value       = "${var.region}.ocir.io"
}

output "ocir_namespace" {
  description = "Namespace (tenancy namespace) de OCIR."
  value       = var.namespace
}

output "repository_ids" {
  description = "Map de servicio -> OCID del repositorio OCIR."
  value       = { for k, v in oci_artifacts_container_repository.lv_repos : k => v.id }
}

output "image_base_path" {
  description = "Path base para referenciar imágenes: <endpoint>/<namespace>/lv-experiment/linea-verde/<service>:<tag>"
  value       = "${var.region}.ocir.io/${var.namespace}/lv-experiment/linea-verde"
}
