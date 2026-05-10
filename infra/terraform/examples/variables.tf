# examples/variables.tf

variable "tenancy_ocid" {
  description = "OCID del tenancy raíz de OCI. Requerido para autenticación."
  type        = string
  default     = ""
}

variable "user_ocid" {
  description = "OCID del usuario OCI con permisos para crear los recursos."
  type        = string
  default     = ""
}

variable "fingerprint" {
  description = "Fingerprint de la clave API del usuario OCI."
  type        = string
  default     = ""
}

variable "private_key_path" {
  description = "Path al archivo PEM de la clave privada API de OCI."
  type        = string
  default     = "~/.oci/oci_api_key.pem"
}

variable "region" {
  description = "Región OCI donde se despliega la infraestructura (ej: sa-saopaulo-1)."
  type        = string
  default     = ""
}

variable "prefix" {
  description = "Prefijo para nombrar todos los recursos."
  type        = string
  default     = "lv"
}

variable "db_engine" {
  description = "Motor de base de datos: 'postgres' (recomendado, default) o 'atp' (Oracle, solo si Cumplimiento lo exige)."
  type        = string
  default     = "postgres"
}

variable "db_password" {
  description = "Contraseña del administrador de base de datos. Proveer vía TF_VAR_db_password."
  type        = string
  sensitive   = true
  default     = ""
}

variable "vcn_cidr" {
  description = "CIDR de la VCN principal."
  type        = string
  default     = "10.0.0.0/16"
}

variable "kubernetes_version" {
  description = "Versión de Kubernetes OKE."
  type        = string
  default     = "v1.30.4"
}

variable "node_image_id" {
  description = "OCID de la imagen de nodo OKE. Obtener con: oci ce node-pool-option get --node-pool-option-id all."
  type        = string
  default     = ""
}

variable "availability_domain_1" {
  description = "Primer AD para el node pool OKE."
  type        = string
  default     = "AD-1"
}

variable "availability_domain_2" {
  description = "Segundo AD para el node pool OKE (HA multi-AD)."
  type        = string
  default     = "AD-2"
}

variable "ocir_namespace" {
  description = "Tenancy namespace para OCIR. Obtener con: oci os ns get."
  type        = string
  default     = ""
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
