# oke/variables.tf

variable "compartment_ocid" {
  description = "OCID del compartment donde se crea el cluster OKE."
  type        = string
  default     = ""
}

variable "vcn_id" {
  description = "OCID de la VCN donde se despliega OKE."
  type        = string
  default     = ""
}

variable "api_subnet_id" {
  description = "OCID de la subnet pública para el endpoint de la API de OKE."
  type        = string
  default     = ""
}

variable "worker_subnet_id" {
  description = "OCID de la subnet privada para los nodos worker."
  type        = string
  default     = ""
}

variable "pod_subnet_id" {
  description = "OCID de la subnet privada para los pods (CNI OCI_VCN_IP_NATIVE)."
  type        = string
  default     = ""
}

variable "kubernetes_version" {
  description = "Versión de Kubernetes para OKE (alineada con versions.env KIND_NODE_IMAGE)."
  type        = string
  default     = "v1.30.4"
}

variable "prefix" {
  description = "Prefijo para nombrar los recursos OKE."
  type        = string
  default     = "lv"
}

variable "node_pool_initial_size" {
  description = "Número inicial de nodos en el node pool (autoscaling min=3)."
  type        = number
  default     = 3
}

variable "node_memory_gb" {
  description = "Memoria en GiB por nodo E5.Flex."
  type        = number
  default     = 32
}

variable "node_ocpus" {
  description = "OCPUs por nodo E5.Flex."
  type        = number
  default     = 4
}

variable "node_image_id" {
  description = "OCID de la imagen OKE Worker para el node pool. Consultar con: oci ce node-pool-option get."
  type        = string
  default     = ""
}

variable "availability_domain_1" {
  description = "Primer Availability Domain para el node pool."
  type        = string
  default     = "AD-1"
}

variable "availability_domain_2" {
  description = "Segundo Availability Domain para el node pool (HA multi-AD)."
  type        = string
  default     = "AD-2"
}

variable "tags" {
  description = "Tags freeform aplicados a todos los recursos OKE."
  type        = map(string)
  default = {
    proyecto = "linea-verde"
    equipo   = "banco-z"
  }
}
