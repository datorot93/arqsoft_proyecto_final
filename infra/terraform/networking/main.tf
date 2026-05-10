# networking/main.tf
# VCN multi-AD con subnets para OKE, base de datos y FastConnect placeholder.
# Banco Z – Línea Verde — ref: diagramas_final/despliegue.png

terraform {
  required_version = "~> 1.9.6"
  required_providers {
    oci = {
      source  = "oracle/oci"
      version = "~> 6.10"
    }
  }
}

# ── VCN ──────────────────────────────────────────────────────────────────────

resource "oci_core_vcn" "lv_vcn" {
  compartment_id = var.compartment_ocid
  cidr_blocks    = [var.vcn_cidr]
  display_name   = "${var.prefix}-vcn"
  dns_label      = "lvvcn"

  freeform_tags = var.tags
}

# ── Internet Gateway ──────────────────────────────────────────────────────────

resource "oci_core_internet_gateway" "lv_igw" {
  compartment_id = var.compartment_ocid
  vcn_id         = oci_core_vcn.lv_vcn.id
  display_name   = "${var.prefix}-igw"
  enabled        = true

  freeform_tags = var.tags
}

# ── NAT Gateway (para nodos de worker OKE sin IP pública) ────────────────────

resource "oci_core_nat_gateway" "lv_nat" {
  compartment_id = var.compartment_ocid
  vcn_id         = oci_core_vcn.lv_vcn.id
  display_name   = "${var.prefix}-nat"

  freeform_tags = var.tags
}

# ── Service Gateway (acceso a OCI Services sin salir a internet) ─────────────

data "oci_core_services" "all_oci_services" {}

resource "oci_core_service_gateway" "lv_sgw" {
  compartment_id = var.compartment_ocid
  vcn_id         = oci_core_vcn.lv_vcn.id
  display_name   = "${var.prefix}-sgw"

  services {
    service_id = data.oci_core_services.all_oci_services.services[0].id
  }

  freeform_tags = var.tags
}

# ── Route Tables ─────────────────────────────────────────────────────────────

resource "oci_core_route_table" "public_rt" {
  compartment_id = var.compartment_ocid
  vcn_id         = oci_core_vcn.lv_vcn.id
  display_name   = "${var.prefix}-public-rt"

  route_rules {
    destination       = "0.0.0.0/0"
    destination_type  = "CIDR_BLOCK"
    network_entity_id = oci_core_internet_gateway.lv_igw.id
  }

  freeform_tags = var.tags
}

resource "oci_core_route_table" "private_rt" {
  compartment_id = var.compartment_ocid
  vcn_id         = oci_core_vcn.lv_vcn.id
  display_name   = "${var.prefix}-private-rt"

  route_rules {
    destination       = "0.0.0.0/0"
    destination_type  = "CIDR_BLOCK"
    network_entity_id = oci_core_nat_gateway.lv_nat.id
  }

  route_rules {
    destination       = data.oci_core_services.all_oci_services.services[0].cidr_block
    destination_type  = "SERVICE_CIDR_BLOCK"
    network_entity_id = oci_core_service_gateway.lv_sgw.id
  }

  freeform_tags = var.tags
}

# ── Security Lists ────────────────────────────────────────────────────────────

resource "oci_core_security_list" "oke_api_sl" {
  compartment_id = var.compartment_ocid
  vcn_id         = oci_core_vcn.lv_vcn.id
  display_name   = "${var.prefix}-oke-api-sl"

  ingress_security_rules {
    protocol    = "6" # TCP
    source      = "0.0.0.0/0"
    description = "Acceso HTTPS al endpoint de la API de OKE"
    tcp_options {
      min = 443
      max = 443
    }
  }

  egress_security_rules {
    protocol         = "all"
    destination      = "0.0.0.0/0"
    description      = "Salida irrestricta"
    destination_type = "CIDR_BLOCK"
  }

  freeform_tags = var.tags
}

resource "oci_core_security_list" "oke_worker_sl" {
  compartment_id = var.compartment_ocid
  vcn_id         = oci_core_vcn.lv_vcn.id
  display_name   = "${var.prefix}-oke-worker-sl"

  ingress_security_rules {
    protocol    = "all"
    source      = var.vcn_cidr
    description = "Tráfico intra-VCN"
  }

  egress_security_rules {
    protocol         = "all"
    destination      = "0.0.0.0/0"
    description      = "Salida irrestricta"
    destination_type = "CIDR_BLOCK"
  }

  freeform_tags = var.tags
}

resource "oci_core_security_list" "db_sl" {
  compartment_id = var.compartment_ocid
  vcn_id         = oci_core_vcn.lv_vcn.id
  display_name   = "${var.prefix}-db-sl"

  ingress_security_rules {
    protocol    = "6"
    source      = var.oke_worker_subnet_cidr
    description = "Postgres/ATP desde workers OKE"
    tcp_options {
      min = 5432
      max = 5432
    }
  }

  ingress_security_rules {
    protocol    = "6"
    source      = var.oke_worker_subnet_cidr
    description = "ATP HTTPS desde workers OKE"
    tcp_options {
      min = 1522
      max = 1522
    }
  }

  egress_security_rules {
    protocol         = "all"
    destination      = "0.0.0.0/0"
    description      = "Salida irrestricta"
    destination_type = "CIDR_BLOCK"
  }

  freeform_tags = var.tags
}

# ── Subnets ───────────────────────────────────────────────────────────────────

resource "oci_core_subnet" "oke_api_subnet" {
  compartment_id    = var.compartment_ocid
  vcn_id            = oci_core_vcn.lv_vcn.id
  cidr_block        = var.oke_api_subnet_cidr
  display_name      = "${var.prefix}-oke-api-subnet"
  dns_label         = "okeapi"
  route_table_id    = oci_core_route_table.public_rt.id
  security_list_ids = [oci_core_security_list.oke_api_sl.id]

  freeform_tags = var.tags
}

resource "oci_core_subnet" "oke_worker_subnet" {
  compartment_id             = var.compartment_ocid
  vcn_id                     = oci_core_vcn.lv_vcn.id
  cidr_block                 = var.oke_worker_subnet_cidr
  display_name               = "${var.prefix}-oke-worker-subnet"
  dns_label                  = "okeworker"
  route_table_id             = oci_core_route_table.private_rt.id
  security_list_ids          = [oci_core_security_list.oke_worker_sl.id]
  prohibit_public_ip_on_vnic = true

  freeform_tags = var.tags
}

resource "oci_core_subnet" "db_subnet" {
  compartment_id             = var.compartment_ocid
  vcn_id                     = oci_core_vcn.lv_vcn.id
  cidr_block                 = var.db_subnet_cidr
  display_name               = "${var.prefix}-db-subnet"
  dns_label                  = "dbsubnet"
  route_table_id             = oci_core_route_table.private_rt.id
  security_list_ids          = [oci_core_security_list.db_sl.id]
  prohibit_public_ip_on_vnic = true

  freeform_tags = var.tags
}

# ── FastConnect placeholder ───────────────────────────────────────────────────
# El DRG se aprovisiona aquí; la conexión física con el datacenter del banco
# requiere un ticket al equipo de networking de OCI (FastConnect Partner o Direct).
# Ver: docs/experimento_asr.md §8 Fase A (FastConnect simulado por VPN).

resource "oci_core_drg" "lv_drg" {
  compartment_id = var.compartment_ocid
  display_name   = "${var.prefix}-drg"

  freeform_tags = var.tags
}

resource "oci_core_drg_attachment" "lv_drg_vcn" {
  drg_id       = oci_core_drg.lv_drg.id
  display_name = "${var.prefix}-drg-vcn-attachment"

  network_details {
    id   = oci_core_vcn.lv_vcn.id
    type = "VCN"
  }
}
