# examples/main.tf
# Composición end-to-end de todos los módulos de Línea Verde en OCI.
# Banco Z – Línea Verde — ref: diagramas_final/despliegue.png
#
# USO:
#   terraform init
#   terraform plan -out=tfplan
#   terraform apply tfplan
#
# VARIABLES REQUERIDAS (setear via TF_VAR_* o .tfvars):
#   tenancy_ocid, user_ocid, fingerprint, private_key_path, region, compartment_ocid, db_password

terraform {
  required_version = "~> 1.9.6"
  required_providers {
    oci = {
      source  = "oracle/oci"
      version = "~> 6.10"
    }
  }
}

provider "oci" {
  tenancy_ocid     = var.tenancy_ocid
  user_ocid        = var.user_ocid
  fingerprint      = var.fingerprint
  private_key_path = var.private_key_path
  region           = var.region
}

# ── IAM ───────────────────────────────────────────────────────────────────────

module "iam" {
  source       = "../iam"
  tenancy_ocid = var.tenancy_ocid
  prefix       = var.prefix
  tags         = var.tags
}

# ── Networking ────────────────────────────────────────────────────────────────

module "networking" {
  source           = "../networking"
  compartment_ocid = module.iam.compartment_id
  prefix           = var.prefix
  vcn_cidr         = var.vcn_cidr
  tags             = var.tags
}

# ── OKE ───────────────────────────────────────────────────────────────────────

module "oke" {
  source              = "../oke"
  compartment_ocid    = module.iam.compartment_id
  vcn_id              = module.networking.vcn_id
  api_subnet_id       = module.networking.oke_api_subnet_id
  worker_subnet_id    = module.networking.oke_worker_subnet_id
  pod_subnet_id       = module.networking.oke_worker_subnet_id
  kubernetes_version  = var.kubernetes_version
  prefix              = var.prefix
  node_image_id       = var.node_image_id
  availability_domain_1 = var.availability_domain_1
  availability_domain_2 = var.availability_domain_2
  tags                = var.tags
}

# ── Base de datos — 3 shards (pe/mx/co) ──────────────────────────────────────

module "db_pe" {
  source           = "../db"
  compartment_ocid = module.iam.compartment_id
  db_engine        = var.db_engine
  pais             = "pe"
  db_subnet_id     = module.networking.db_subnet_id
  db_password      = var.db_password
  prefix           = var.prefix
  tags             = var.tags
}

module "db_mx" {
  source           = "../db"
  compartment_ocid = module.iam.compartment_id
  db_engine        = var.db_engine
  pais             = "mx"
  db_subnet_id     = module.networking.db_subnet_id
  db_password      = var.db_password
  prefix           = var.prefix
  tags             = var.tags
}

module "db_co" {
  source           = "../db"
  compartment_ocid = module.iam.compartment_id
  db_engine        = var.db_engine
  pais             = "co"
  db_subnet_id     = module.networking.db_subnet_id
  db_password      = var.db_password
  prefix           = var.prefix
  tags             = var.tags
}

# ── OCI Streaming ─────────────────────────────────────────────────────────────

module "streaming" {
  source           = "../streaming"
  compartment_ocid = module.iam.compartment_id
  prefix           = var.prefix
  tags             = var.tags
}

# ── OCIR ──────────────────────────────────────────────────────────────────────

module "registry" {
  source           = "../registry"
  compartment_ocid = module.iam.compartment_id
  namespace        = var.ocir_namespace
  region           = var.region
  tags             = var.tags
}
