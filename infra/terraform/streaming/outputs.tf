# streaming/outputs.tf

output "streaming_bootstrap" {
  description = "Kafka bootstrap server endpoint de OCI Streaming (compatible con Redpanda del experimento local)."
  value       = "${oci_streaming_stream_pool.lv_pool.endpoint_fqdn}:9092"
}

output "stream_pool_id" {
  description = "OCID del Stream Pool de OCI Streaming."
  value       = oci_streaming_stream_pool.lv_pool.id
}

output "cdt_eventos_stream_id" {
  description = "OCID del stream cdt.eventos."
  value       = oci_streaming_stream.cdt_eventos.id
}

output "stream_pool_endpoint" {
  description = "FQDN del endpoint del Stream Pool (para configurar bootstrap.servers)."
  value       = oci_streaming_stream_pool.lv_pool.endpoint_fqdn
}
