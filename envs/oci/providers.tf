# Credentials come from the OCI CLI configuration file (~/.oci/config, API signing key): nothing
# secret lives in this directory. Profile and region are variables.
provider "oci" {
  region              = var.region
  config_file_profile = var.oci_config_profile
}
