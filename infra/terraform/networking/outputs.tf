# networking/outputs.tf

output "vcn_id" {
  description = "OCID de la VCN creada."
  value       = oci_core_vcn.lv_vcn.id
}

output "oke_api_subnet_id" {
  description = "OCID de la subnet pública del endpoint de OKE."
  value       = oci_core_subnet.oke_api_subnet.id
}

output "oke_worker_subnet_id" {
  description = "OCID de la subnet privada de workers OKE."
  value       = oci_core_subnet.oke_worker_subnet.id
}

output "db_subnet_id" {
  description = "OCID de la subnet privada de base de datos."
  value       = oci_core_subnet.db_subnet.id
}

output "drg_id" {
  description = "OCID del Dynamic Routing Gateway (FastConnect placeholder)."
  value       = oci_core_drg.lv_drg.id
}
