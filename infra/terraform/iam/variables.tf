# iam/variables.tf

variable "tenancy_ocid" {
  description = "OCID del tenancy raíz de OCI."
  type        = string
  default     = ""
}

variable "prefix" {
  description = "Prefijo para nombrar todos los recursos IAM."
  type        = string
  default     = "lv"
}

variable "tags" {
  description = "Tags freeform aplicados a todos los recursos IAM."
  type        = map(string)
  default = {
    proyecto = "linea-verde"
    equipo   = "banco-z"
  }
}
