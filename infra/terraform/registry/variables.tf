# registry/variables.tf

variable "compartment_ocid" {
  description = "OCID del compartment donde se crean los repositorios OCIR."
  type        = string
  default     = ""
}

variable "namespace" {
  description = "Namespace (tenancy namespace) de OCIR. Obtener con: oci os ns get."
  type        = string
  default     = ""
}

variable "region" {
  description = "Región OCI donde está el registry (ej: sa-saopaulo-1)."
  type        = string
  default     = ""
}

variable "tags" {
  description = "Tags freeform aplicados a los repositorios OCIR."
  type        = map(string)
  default = {
    proyecto = "linea-verde"
    equipo   = "banco-z"
  }
}
