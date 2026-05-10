# db/variables.tf

variable "compartment_ocid" {
  description = "OCID del compartment donde se crea el sistema de base de datos."
  type        = string
  default     = ""
}

variable "db_engine" {
  description = <<-EOT
    Motor de base de datos a aprovisionar.
    - "postgres": OCI Database with PostgreSQL (recomendado — drop-in con CloudNativePG del experimento local).
    - "atp":      Autonomous Database ATP (Oracle — requiere migración de driver y schema; solo si Cumplimiento lo exige).
    Ver: docs/experimento_asr.md §6.4.11 Matiz 3.
  EOT
  type        = string
  default     = "postgres"

  validation {
    condition     = contains(["postgres", "atp"], var.db_engine)
    error_message = "db_engine debe ser 'postgres' (recomendado) o 'atp' (Oracle). Ver §6.4.11."
  }
}

variable "pais" {
  description = "Código del país para el shard de base de datos (pe, mx, co)."
  type        = string
  default     = "pe"

  validation {
    condition     = contains(["pe", "mx", "co"], var.pais)
    error_message = "pais debe ser 'pe', 'mx' o 'co'."
  }
}

variable "db_subnet_id" {
  description = "OCID de la subnet privada para el sistema de base de datos."
  type        = string
  default     = ""
}

variable "db_password" {
  description = "Contraseña para el usuario administrador de la base de datos. Proveer vía variable de entorno TF_VAR_db_password o secret."
  type        = string
  sensitive   = true
  default     = ""
}

variable "postgres_version" {
  description = "Versión de PostgreSQL para OCI Database with PostgreSQL."
  type        = string
  default     = "14"
}

variable "postgres_shape" {
  description = "Shape del sistema PostgreSQL gestionado de OCI."
  type        = string
  default     = "PostgreSQL.VM.Standard.E4.Flex.4.64GB"
}

variable "ha_enabled" {
  description = "Habilitar alta disponibilidad (2 instancias) para PostgreSQL gestionado."
  type        = bool
  default     = false
}

variable "atp_cpu_cores" {
  description = "Número de CPU cores para Autonomous Database ATP (solo aplica si db_engine=atp)."
  type        = number
  default     = 2
}

variable "prefix" {
  description = "Prefijo para nombrar los recursos de base de datos."
  type        = string
  default     = "lv"
}

variable "tags" {
  description = "Tags freeform aplicados a todos los recursos de base de datos."
  type        = map(string)
  default = {
    proyecto = "linea-verde"
    equipo   = "banco-z"
  }
}
