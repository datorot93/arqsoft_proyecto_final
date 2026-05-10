# oke/main.tf
# Cluster OKE 1.30 con node pool E5.Flex autoscaling 3-12 nodos.
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

# ── Cluster OKE ───────────────────────────────────────────────────────────────

resource "oci_containerengine_cluster" "lv_cluster" {
  compartment_id     = var.compartment_ocid
  kubernetes_version = var.kubernetes_version
  name               = "${var.prefix}-cluster"
  vcn_id             = var.vcn_id

  cluster_pod_network_options {
    cni_type = "OCI_VCN_IP_NATIVE"
  }

  endpoint_config {
    is_public_ip_enabled = true
    subnet_id            = var.api_subnet_id
  }

  options {
    add_ons {
      is_kubernetes_dashboard_enabled = false
      is_tiller_enabled               = false
    }

    kubernetes_network_config {
      pods_cidr     = "10.96.0.0/16"
      services_cidr = "10.97.0.0/16"
    }

    persistent_volume_config {
      freeform_tags = var.tags
    }

    service_lb_config {
      freeform_tags = var.tags
    }
  }

  image_policy_config {
    is_policy_enabled = false
  }

  type = "ENHANCED_CLUSTER"

  freeform_tags = var.tags
}

# ── Node Pool E5.Flex con autoscaling 3-12 ────────────────────────────────────

resource "oci_containerengine_node_pool" "lv_node_pool" {
  cluster_id         = oci_containerengine_cluster.lv_cluster.id
  compartment_id     = var.compartment_ocid
  kubernetes_version = var.kubernetes_version
  name               = "${var.prefix}-node-pool"

  node_config_details {
    size = var.node_pool_initial_size

    placement_configs {
      availability_domain = var.availability_domain_1
      subnet_id           = var.worker_subnet_id
    }

    placement_configs {
      availability_domain = var.availability_domain_2
      subnet_id           = var.worker_subnet_id
    }

    node_pool_pod_network_option_details {
      cni_type          = "OCI_VCN_IP_NATIVE"
      max_pods_per_node = 31
      pod_subnet_ids    = [var.pod_subnet_id]
    }

    freeform_tags = var.tags
  }

  node_shape = "VM.Standard.E5.Flex"

  node_shape_config {
    memory_in_gbs = var.node_memory_gb
    ocpus         = var.node_ocpus
  }

  node_source_details {
    image_id    = var.node_image_id
    source_type = "IMAGE"
  }

  node_metadata = {
    user_data = base64encode(templatefile("${path.module}/cloud-init.sh.tpl", {
      cluster_id = oci_containerengine_cluster.lv_cluster.id
    }))
  }

  # Autoscaling 3-12 nodos gestionado por el Cluster Autoscaler de OKE
  initial_node_labels {
    key   = "app.kubernetes.io/part-of"
    value = "linea-verde"
  }

  freeform_tags = var.tags
}
