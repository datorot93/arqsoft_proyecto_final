# oke/outputs.tf

output "cluster_id" {
  description = "OCID del cluster OKE creado."
  value       = oci_containerengine_cluster.lv_cluster.id
}

output "oke_kubeconfig" {
  description = "Comando para obtener el kubeconfig del cluster OKE. Ejecutar: oci ce cluster create-kubeconfig --cluster-id <cluster_id> --file ~/.kube/config --region <region> --token-version 2.0.0"
  value       = "oci ce cluster create-kubeconfig --cluster-id ${oci_containerengine_cluster.lv_cluster.id} --file ~/.kube/config --token-version 2.0.0"
}

output "node_pool_id" {
  description = "OCID del node pool E5.Flex."
  value       = oci_containerengine_node_pool.lv_node_pool.id
}

output "kubernetes_version" {
  description = "Versión de Kubernetes del cluster."
  value       = oci_containerengine_cluster.lv_cluster.kubernetes_version
}
