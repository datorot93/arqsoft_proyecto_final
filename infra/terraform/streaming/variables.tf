# streaming/variables.tf

variable "compartment_ocid" {
  description = "OCID del compartment donde se crea el Stream Pool."
  type        = string
  default     = ""
}

variable "prefix" {
  description = "Prefijo para nombrar el Stream Pool."
  type        = string
  default     = "lv"
}

variable "log_retention_hours" {
  description = "Retención de mensajes en horas (por defecto 24h)."
  type        = number
  default     = 24
}

variable "cdt_eventos_partitions" {
  description = "Número de particiones para el tópico cdt.eventos."
  type        = number
  default     = 3
}

variable "default_partitions" {
  description = "Número de particiones por defecto para tópicos secundarios."
  type        = number
  default     = 1
}

variable "tags" {
  description = "Tags freeform aplicados a todos los recursos de streaming."
  type        = map(string)
  default = {
    proyecto = "linea-verde"
    equipo   = "banco-z"
  }
}
