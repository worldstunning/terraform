#####################################
# TERRAFORM & PROVIDER
#####################################

terraform {
  required_version = ">= 0.13"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "4.57.0"
    }
  }
}

provider "azurerm" {
  features {}
}

data "azurerm_subscription" "current" {}

#####################################
# LOCALS
#####################################

locals {
  location       = "centralindia"
  resource_group = "rg-01"

  tags = {
    "Business Unit" = "IT"
    "Cost Center"   = "CC-1001"
  }

  vnet_id   = "/subscriptions/${data.azurerm_subscription.current.subscription_id}/resourceGroups/rg-01/providers/Microsoft.Network/virtualNetworks/vnet-01"
  aks_subnet_id = "${local.vnet_id}/subnets/aks-subnet"
  aci_subnet_id = "${local.vnet_id}/subnets/aci-subnet"
  psql_subnet_id = "${local.vnet_id}/subnets/psql-subnet"
}

#####################################
# AZURE POLICIES (CORRECTED)
#####################################

resource "azurerm_policy_definition" "mandatory_tags" {
  name         = "mandatory-tags"
  policy_type = "Custom"
  mode        = "Indexed"
  display_name = "Require Business Unit and Cost Center tags"

  policy_rule = jsonencode({
    if = {
      anyOf = [
        { field = "tags['Business Unit']", exists = "false" },
        { field = "tags['Cost Center']", exists = "false" }
      ]
    }
    then = {
      effect = "deny"
    }
  })
}

resource "azurerm_policy_definition" "allowed_locations" {
  name         = "allowed-locations"
  policy_type = "Custom"
  mode        = "All"
  display_name = "Allow only Central India and South India"

  policy_rule = jsonencode({
    if = {
      not = {
        field = "location"
        in = ["centralindia", "southindia"]
      }
    }
    then = {
      effect = "deny"
    }
  })
}

resource "azurerm_subscription_policy_assignment" "mandatory_tags" {
  name                 = "mandatory-tags"
  policy_definition_id = azurerm_policy_definition.mandatory_tags.id
  subscription_id      = data.azurerm_subscription.current.subscription_id
}

resource "azurerm_subscription_policy_assignment" "allowed_locations" {
  name                 = "allowed-locations"
  policy_definition_id = azurerm_policy_definition.allowed_locations.id
  subscription_id      = data.azurerm_subscription.current.subscription_id
}

#####################################
# ACR (PRIVATE NETWORK ACCESS DISABLED)
#####################################

resource "azurerm_container_registry" "acr" {
  name                = "acrprivate01"
  resource_group_name = local.resource_group
  location            = local.location
  sku                 = "Premium"
  admin_enabled       = false

  public_network_access_enabled = false

  tags = local.tags
}

#####################################
# AKS (PRIVATE CLUSTER – VALID)
#####################################

resource "azurerm_kubernetes_cluster" "aks" {
  name                = "aks-private-01"
  location            = local.location
  resource_group_name = local.resource_group
  dns_prefix          = "aksprivate"

  private_cluster_enabled = true
  private_dns_zone_id     = "System"

  default_node_pool {
    name           = "system"
    node_count     = 2
    vm_size        = "Standard_DS2_v2"
    vnet_subnet_id = local.aks_subnet_id
  }

  identity {
    type = "SystemAssigned"
  }

  network_profile {
    network_plugin = "azure"
    outbound_type  = "loadBalancer"
  }

  tags = local.tags
}

#####################################
# AZURE CONTAINER INSTANCE (PRIVATE)
#####################################

resource "azurerm_container_group" "aci" {
  name                = "aci-private-01"
  location            = local.location
  resource_group_name = local.resource_group
  os_type             = "Linux"

  ip_address_type = "Private"
  subnet_ids      = [local.aci_subnet_id]

  container {
    name   = "app"
    image  = "mcr.microsoft.com/azuredocs/aci-helloworld"
    cpu    = 1
    memory = 1

    ports {
      port     = 80
      protocol = "TCP"
    }
  }

  tags = local.tags
}

#####################################
# POSTGRESQL FLEXIBLE SERVER (PRIVATE)
#####################################

resource "azurerm_postgresql_flexible_server" "psql" {
  name                = "psql-flex-01"
  resource_group_name = local.resource_group
  location            = local.location

  administrator_login    = "pgadmin"
  administrator_password = "P@ssword12345!"
  version                = "15"

  delegated_subnet_id = local.psql_subnet_id
  private_dns_zone_id = null

  sku_name   = "GP_Standard_D2s_v3"
  storage_mb = 32768

  tags = local.tags
}

resource "azurerm_postgresql_flexible_server_database" "employee_db" {
  name      = "employee"
  server_id = azurerm_postgresql_flexible_server.psql.id
  charset   = "UTF8"
  collation = "en_US.utf8"
}

#####################################
# KEY VAULT (NO PUBLIC ACCESS)
#####################################

resource "azurerm_key_vault" "kv" {
  name                = "kv-private-01"
  location            = local.location
  resource_group_name = local.resource_group
  tenant_id           = data.azurerm_subscription.current.tenant_id
  sku_name            = "standard"

  public_network_access_enabled = false
  purge_protection_enabled      = true
  soft_delete_retention_days    = 7

  tags = local.tags
}
