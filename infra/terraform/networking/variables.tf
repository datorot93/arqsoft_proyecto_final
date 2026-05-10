# networking/variables.tf

variable "compartment_ocid" {
  description = "OCID del compartment donde se crean los recursos de red."
  type        = string
}

variable "prefix" {
  description = "Prefijo para nombrar todos los recursos (ej: lv-prod)."
  type        = string
  default     = "lv"
}

variable "vcn_cidr" {
  description = "CIDR block de la VCN principal."
  type        = string
  default     = "10.0.0.0/16"
}

variable "oke_api_subnet_cidr" {
  description = "CIDR de la subnet pública para el endpoint de la API de OKE."
  type        = string
  default     = "10.0.0.0/28"
}

variable "oke_worker_subnet_cidr" {
  description = "CIDR de la subnet privada para los nodos worker de OKE."
  type        = string
  default     = "10.0.1.0/24"
}

variable "db_subnet_cidr" {
  description = "CIDR de la subnet privada para el servicio de base de datos."
  type        = string
  default     = "10.0.2.0/24"
}

variable "tags" {
  description = "Tags freeform aplicados a todos los recursos."
  type        = map(string)
  default = {
    proyecto = "linea-verde"
    equipo   = "banco-z"
    fase     = "f7-reproducibilidad"
  }
}
