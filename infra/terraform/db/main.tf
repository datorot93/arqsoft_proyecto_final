# db/main.tf
# Módulo de base de datos parametrizable: OCI Database with PostgreSQL (default)
# o Autonomous Database ATP.
#
# DECISIÓN ARQUITECTÓNICA (§6.4.11 opción B):
#   db_engine = "postgres"  → OCI Database with PostgreSQL (gestionado, drop-in
#                             con CloudNativePG del experimento local).
#   db_engine = "atp"       → Autonomous Database ATP (Oracle; NO drop-in con
#                             PostgreSQL — requiere migración de driver JDBC y
#                             dialecto SQL). Solo usar si Cumplimiento exige ATP.
#
# Ref: docs/experimento_asr.md §6.4.11, diagramas_final/despliegue.png

terraform {
  required_version = "~> 1.9.6"
  required_providers {
    oci = {
      source  = "oracle/oci"
      version = "~> 6.10"
    }
  }
}

# ── OCI Database with PostgreSQL (opción B — recomendada) ────────────────────

resource "oci_psql_db_system" "lv_postgres" {
  count = var.db_engine == "postgres" ? 1 : 0

  compartment_id     = var.compartment_ocid
  display_name       = "${var.prefix}-postgres-${var.pais}"
  db_version         = var.postgres_version
  instance_count     = var.ha_enabled ? 2 : 1
  shape              = var.postgres_shape
  storage_details {
    is_regionally_durable = true
    system_type           = "OCI_OPTIMIZED_STORAGE"
  }

  network_details {
    subnet_id = var.db_subnet_id
  }

  credentials {
    username = "lineaverde"
    password_details {
      password_type = "PLAIN_TEXT"
      password      = var.db_password
    }
  }

  # Nota: parámetros como max_connections se definen vía un recurso
  # `oci_psql_configuration` separado y se referencian con `config_id` en
  # el `oci_psql_db_system`. Para el experimento se mantiene el config
  # default del servicio. Producción puede crear un Configuration ad-hoc.

  freeform_tags = merge(var.tags, { pais = var.pais })
}

# ── Autonomous Database ATP (opción A — solo si Cumplimiento lo exige) ────────

resource "oci_database_autonomous_database" "lv_atp" {
  count = var.db_engine == "atp" ? 1 : 0

  compartment_id          = var.compartment_ocid
  display_name            = "${var.prefix}-atp-${var.pais}"
  db_name                 = "${var.prefix}atp${var.pais}"
  admin_password          = var.db_password
  cpu_core_count          = var.atp_cpu_cores
  data_storage_size_in_tbs = 1
  db_workload             = "OLTP"
  is_auto_scaling_enabled = true
  is_free_tier            = false

  subnet_id = var.db_subnet_id

  # Advertencia: ATP es Oracle Database, NO PostgreSQL.
  # Requiere driver ojdbc11, dialecto Hibernate Oracle, y migración de schema.
  # Ver: docs/experimento_asr.md §6.4.11 Matiz 3.

  freeform_tags = merge(var.tags, { pais = var.pais, motor = "oracle-atp" })
}
