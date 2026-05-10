# iam/outputs.tf

output "compartment_id" {
  description = "OCID del compartment creado para Línea Verde."
  value       = oci_identity_compartment.lv_compartment.id
}

output "compartment_name" {
  description = "Nombre del compartment de Línea Verde."
  value       = oci_identity_compartment.lv_compartment.name
}

output "oke_nodes_dg_id" {
  description = "OCID del dynamic group para nodos OKE."
  value       = oci_identity_dynamic_group.oke_nodes.id
}

output "oke_pods_dg_id" {
  description = "OCID del dynamic group para pods OKE con workload identity."
  value       = oci_identity_dynamic_group.oke_pods.id
}
