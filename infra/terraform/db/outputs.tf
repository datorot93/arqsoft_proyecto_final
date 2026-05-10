# db/outputs.tf

output "db_connection_string" {
  description = "String de conexión JDBC a la base de datos aprovisionada."
  value = var.db_engine == "postgres" ? (
    length(oci_psql_db_system.lv_postgres) > 0
    ? "jdbc:postgresql://${oci_psql_db_system.lv_postgres[0].id}.${var.pais}.oraclecloud.com:5432/lineaverde"
    : ""
  ) : (
    length(oci_database_autonomous_database.lv_atp) > 0
    ? "jdbc:oracle:thin:@${oci_database_autonomous_database.lv_atp[0].db_name}_high?TNS_ADMIN=/path/to/wallet"
    : ""
  )
  sensitive = false
}

output "db_engine_used" {
  description = "Motor de base de datos aprovisionado (postgres o atp)."
  value       = var.db_engine
}

output "db_system_id" {
  description = "OCID del sistema de base de datos (postgres o atp)."
  value = var.db_engine == "postgres" ? (
    length(oci_psql_db_system.lv_postgres) > 0
    ? oci_psql_db_system.lv_postgres[0].id
    : ""
  ) : (
    length(oci_database_autonomous_database.lv_atp) > 0
    ? oci_database_autonomous_database.lv_atp[0].id
    : ""
  )
}
