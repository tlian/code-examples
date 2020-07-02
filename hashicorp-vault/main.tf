###################
# Local Variables #
###################

variable "service_principal_name" {
  type = string
}

variable "service_principal_id" {
  type = string
}

variable "service_principal_secret" {
  type = string
}

variable "subscription_id" {
  type = string
}

variable "iog_resource_group_name" {
  type = string
}

variable "iog_subscription_id" {
  type = string
}

variable "sre_subscription_id" {
  type = string
}

variable "domain_prefix" {
  type = string
}

variable "hostname" {
  type    = string
  default = "vault"
}

variable "email_address" {
  type = string
}

variable "certificate_type" {
  type        = string
  description = "staging or production"
  default     = "staging"
}

#############
# Providers #
#############

provider "azurerm" {
  version = "=2.15.0"
  subscription_id = var.subscription_id
  features {}
}

provider "helm" {
  alias = "aks"
  kubernetes {
    host                   = module.kubernetes.host
    client_certificate     = base64decode(module.kubernetes.client_certificate)
    client_key             = base64decode(module.kubernetes.client_key)
    cluster_ca_certificate = base64decode(module.kubernetes.cluster_ca_certificate)
  }
}

provider "kubernetes" {
  load_config_file       = "false"
  host                   = module.kubernetes.host
  client_certificate     = base64decode(module.kubernetes.client_certificate)
  client_key             = base64decode(module.kubernetes.client_key)
  cluster_ca_certificate = base64decode(module.kubernetes.cluster_ca_certificate)
}

#####################
# Pre-Build Modules #
#####################

module "subscription" {
  source = "github.com/Azure-Terraform/terraform-azurerm-subscription-data.git?ref=v1.0.0"
  subscription_id = var.subscription_id
}

module "rules" {
  source = "git@github.com:openrba/python-azure-naming.git?ref=tf"
}

module "metadata"{
  source = "github.com/Azure-Terraform/terraform-azurerm-metadata.git?ref=v1.0.0"

  naming_rules = module.rules.yaml
  
  market              = "us"
  project             = "https://gitlab.ins.risk.regn.net/example/"
  location            = "useast2"
  sre_team            = "iog-core-services"
  environment         = "sandbox"
  product_name        = "lzdemovault"
  business_unit       = "iog"
  product_group       = "core"
  subscription_id     = module.subscription.output.subscription_id
  subscription_type   = "nonprod"
  resource_group_type = "app"
}

module "resource_group" {
  source = "github.com/Azure-Terraform/terraform-azurerm-resource-group.git?ref=v1.0.0"
  
  location = module.metadata.location
  names    = module.metadata.names
  tags     = module.metadata.tags
}

module "kubernetes" {
  source = "github.com/Azure-Terraform/terraform-azurerm-kubernetes.git?ref=v1.1.0"

  kubernetes_version = "1.16.8"
  
  location                 = module.metadata.location
  names                    = module.metadata.names
  tags                     = module.metadata.tags
  resource_group_name      = module.resource_group.name
  service_principal_id     = var.service_principal_id
  service_principal_secret = var.service_principal_secret
  service_principal_name   = var.service_principal_name

  default_node_pool_name                = "default"
  default_node_pool_vm_size             = "Standard_D2s_v3"
  default_node_pool_enable_auto_scaling = true
  default_node_pool_node_min_count      = 1
  default_node_pool_node_max_count      = 5
  default_node_pool_availability_zones  = [1,2,3]

  enable_kube_dashboard = true

}

resource "azurerm_kubernetes_cluster_node_pool" "b2s" {
  name                  = "b2ms"
  kubernetes_cluster_id = module.kubernetes.id
  vm_size               = "Standard_B2s"
  availability_zones    = [1,2,3]
  enable_auto_scaling   = true

  min_count      = 3
  max_count      = 5

  tags = module.metadata.tags
}

resource "kubernetes_storage_class" "azurefile_grs" {
   metadata {
     name = "azurefile-grs"
   }
   storage_provisioner = "kubernetes.io/azure-file"
   reclaim_policy      = "Delete"
   parameters = {
     skuName = "Standard_GRS"
   }
   mount_options = ["dir_mode=0777", "file_mode=0777", "uid=0", "gid=0", "mfsymlinks", "cache=strict"]
}

module "aad-pod-identity" {
  source = "github.com/Azure-Terraform/terraform-azurerm-kubernetes.git//aad-pod-identity?ref=v1.1.0"
  providers = { helm = helm.aks }

  resource_group_name    = module.resource_group.name
  service_principal_name = var.service_principal_name

  aad_pod_identity_version = "1.6.0"
}

module "dns" {
  source = "github.com/Azure-Terraform/terraform-azurerm-dns-zone.git?ref=v1.0.0"

  domain_prefix = var.domain_prefix

  iog_resource_group_name = var.iog_resource_group_name
  iog_subscription_id     = var.iog_subscription_id
  sre_resource_group_name = module.resource_group.name
  sre_subscription_id     = var.sre_subscription_id

  names = module.metadata.names
  tags  = module.metadata.tags
}

resource "azurerm_public_ip" "vault" {
  name                = var.hostname
  resource_group_name = module.kubernetes.node_resource_group
  location            = module.resource_group.location
  allocation_method   = "Static"

  sku = "Standard"

  tags = module.metadata.tags
}

resource "azurerm_dns_a_record" "vault" {
  name                = var.hostname
  zone_name           = module.dns.name
  resource_group_name = module.resource_group.name
  ttl                 = 60
  records             = [azurerm_public_ip.vault.ip_address]
}

module "cert_manager" {
  source    = "git::https://github.com/Azure-Terraform/terraform-azurerm-kubernetes.git//cert-manager?ref=v1.1.0"
  providers = { helm = helm.aks }

  subscription_id = module.subscription.output.subscription_id

  resource_group_name = module.resource_group.name
  location            = module.resource_group.location

  names = module.metadata.names
  tags  = module.metadata.tags

  cert_manager_version = "v0.15.1"

  domains = [module.dns.name]

  issuers = {
    staging = {
      namespace             = "cert-manager"
      cluster_issuer        = true
      email_address         = var.email_address
      domain                = module.dns.name
      letsencrypt_endpoint  = "staging"
    }
    production = {
      namespace             = "cert-manager"
      cluster_issuer        = true
      email_address         = var.email_address
      domain                = module.dns.name
      letsencrypt_endpoint  = "production"
    }
  }
}

module "certificate" {
  source    = "git::https://github.com/Azure-Terraform/terraform-azurerm-kubernetes.git//cert-manager/certificate?ref=v1.1.0"
  providers = { helm = helm.aks }

  certificate_name = "vault"
  namespace = "hashicorp-vault"
  secret_name = "vault-le-certificate"
  issuer_ref_name = module.cert_manager.issuers[var.certificate_type]

  dns_names = [trim(azurerm_dns_a_record.vault.fqdn, ".")]
}

module "nginx_ingress" {
  source    = "git::https://github.com/Azure-Terraform/terraform-azurerm-kubernetes.git//nginx-ingress?ref=v1.1.0"
  providers = { helm = helm.aks }

  helm_chart_version = "1.40.1"
  helm_release_name = "nginx-ingress-vault"

  kubernetes_namespace        = "hashicorp-vault"
  kubernetes_create_namespace = true

  load_balancer_ip     = azurerm_public_ip.vault.ip_address
}

module "vault" {
  source = "github.com/Azure-Terraform/terraform-azurerm-hashicorp-vault.git?ref=ingress"
  providers = { helm = helm.aks }

  resource_group_name = module.resource_group.name
  location            = module.resource_group.location
  names               = module.metadata.names
  tags                = module.metadata.tags

  kubernetes_namespace = "hashicorp-vault"
  kubernetes_node_selector = {"agentpool" = "b2ms"}

  vault_enable_ha              = true
  vault_enable_raft_backend    = true
  vault_version                = "1.4.2"
  vault_agent_injector_version = "0.3.0"
  vault_data_storage_class     = kubernetes_storage_class.azurefile_grs.metadata[0].name

  vault_ingress_enabled         = true
  vault_ingress_hostname        = trim(azurerm_dns_a_record.vault.fqdn, ".")
  vault_ingress_tls_secret_name = module.certificate.secret_name

  vault_enable_ui = true
}

output "aks_login" {
  value = "az aks get-credentials --name ${module.kubernetes.name} --resource-group ${module.resource_group.name}"
}

output "vault_url" {
  value = "https://${trim(azurerm_dns_a_record.vault.fqdn, ".")}"
}