# iam/main.tf
# Compartments, dynamic groups y policies para OKE y servicios del experimento.
# Banco Z – Línea Verde — ref: docs/experimento_asr.md §6.4.6

terraform {
  required_version = "~> 1.9.6"
  required_providers {
    oci = {
      source  = "oracle/oci"
      version = "~> 6.10"
    }
  }
}

# ── Compartment ───────────────────────────────────────────────────────────────

resource "oci_identity_compartment" "lv_compartment" {
  compartment_id = var.tenancy_ocid
  name           = "${var.prefix}-linea-verde"
  description    = "Compartment de Línea Verde — experimento ASR-1/ASR-2"
  enable_delete  = true

  freeform_tags = var.tags
}

# ── Dynamic Groups ────────────────────────────────────────────────────────────

resource "oci_identity_dynamic_group" "oke_nodes" {
  compartment_id = var.tenancy_ocid
  name           = "${var.prefix}-oke-nodes"
  description    = "Nodos worker del cluster OKE de Línea Verde"
  matching_rule  = "ALL {instance.compartment.id = '${oci_identity_compartment.lv_compartment.id}'}"

  freeform_tags = var.tags
}

resource "oci_identity_dynamic_group" "oke_pods" {
  compartment_id = var.tenancy_ocid
  name           = "${var.prefix}-oke-pods"
  description    = "Pods en OKE que acceden a servicios OCI vía workload identity"
  matching_rule  = "ALL {resource.type = 'workloadid', resource.compartment.id = '${oci_identity_compartment.lv_compartment.id}'}"

  freeform_tags = var.tags
}

# ── Policies ──────────────────────────────────────────────────────────────────

resource "oci_identity_policy" "oke_node_policy" {
  compartment_id = var.tenancy_ocid
  name           = "${var.prefix}-oke-node-policy"
  description    = "Permisos requeridos por los nodos worker de OKE"

  statements = [
    "Allow dynamic-group ${oci_identity_dynamic_group.oke_nodes.name} to read secret-family in compartment ${oci_identity_compartment.lv_compartment.name}",
    "Allow dynamic-group ${oci_identity_dynamic_group.oke_nodes.name} to use keys in compartment ${oci_identity_compartment.lv_compartment.name}",
    "Allow dynamic-group ${oci_identity_dynamic_group.oke_nodes.name} to manage repos in compartment ${oci_identity_compartment.lv_compartment.name}",
    "Allow dynamic-group ${oci_identity_dynamic_group.oke_nodes.name} to read objectstorage-namespaces in tenancy",
  ]

  freeform_tags = var.tags
}

resource "oci_identity_policy" "oke_pod_policy" {
  compartment_id = var.tenancy_ocid
  name           = "${var.prefix}-oke-pod-policy"
  description    = "Permisos para pods de Línea Verde (streaming, secrets)"

  statements = [
    "Allow dynamic-group ${oci_identity_dynamic_group.oke_pods.name} to use stream-push in compartment ${oci_identity_compartment.lv_compartment.name}",
    "Allow dynamic-group ${oci_identity_dynamic_group.oke_pods.name} to use stream-pull in compartment ${oci_identity_compartment.lv_compartment.name}",
    "Allow dynamic-group ${oci_identity_dynamic_group.oke_pods.name} to read secret-family in compartment ${oci_identity_compartment.lv_compartment.name}",
  ]

  freeform_tags = var.tags
}
