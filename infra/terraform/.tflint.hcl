config {
  call_module_type = "local"
  force            = false
}

# Plugin terraform built-in (siempre activo). El plugin oficial de tflint
# para OCI (`tflint-ruleset-oci`) requiere instalación explícita y emite
# warnings inevitables si el provider no está configurado con credenciales,
# así que se omite del default config para que el lint estructural pase
# sin tenancy real. CI productivo puede añadirlo cuando los secrets estén
# configurados.
plugin "terraform" {
  enabled = true
  preset  = "recommended"
}

rule "terraform_required_version" {
  enabled = true
}

rule "terraform_required_providers" {
  enabled = true
}

rule "terraform_naming_convention" {
  enabled = false
}

rule "terraform_documented_variables" {
  enabled = true
}

rule "terraform_documented_outputs" {
  enabled = true
}

rule "terraform_typed_variables" {
  enabled = true
}
