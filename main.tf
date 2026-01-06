terraform {
  required_version = ">= 1.5.0"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 3.100"
    }
  }
}

provider "azurerm" {
  features {}
}

data "azurerm_subscription" "current" {}

############################
# COMMON VARIABLES (INLINE)
############################

locals {
  location          = "centralindia"
  resource_group    = "rg-01"

  tags = {
    "Business Unit" = "IT"
    "Cost Center"   = "CC-1001"
  }

  vnet_id               = "/subscriptions/${data.azurerm_subscription.current.subscription_id}/resourceGroups/rg-01/providers/Microsoft.Network/virtualNetworks/vnet-01"
  aks_subnet_id         = "${local.vnet_id}/subnets/aks-subnet"
  private_endpoint_subnet_id = "${local.vnet_id}/subnets/pe-subnet"
  aci_subnet_id         = "${local.vnet_id}/subnets/aci-subnet"
}

############################
# AZURE POLICY DEFINITIONS
############################

resource "azurerm_policy_definition" "mandatory_tags" {
  name         = "mandatory-tags"
  policy_type = "Custom"
  mode        = "Indexed"
  display_name = "Require mandatory tags"

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

resource "azurerm_policy_definition" "deny_public_ip_nic" {
  name         = "deny-public-ip-on-nic"
  policy_type = "Custom"
  mode        = "Indexed"
  display_name = "Deny Public IP on NIC"

  policy_rule = jsonencode({
    if = {
      allOf = [
        { field = "type", equals = "Microsoft.Network/networkInterfaces" },
        { field = "Microsoft.Network/networkInterfaces/ipConfigurations[*].publicIpAddress.id", exists = "true" }
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

resource "azurerm_policy_assignment" "subscription_policies" {
  for_each = {
    tags      = azurerm_policy_definition.mandatory_tags.id
    nopip     = azurerm_policy_definition.deny_public_ip_nic.id
    location  = azurerm_policy_definition.allowed_locations.id
  }

  name                 = each.key
  policy_definition_id = each.value
  scope                = data.azurerm_subscription.current.id
}

############################
# ACR (PRIVATE)
############################

resource "azurerm_container_registry" "acr" {
  name                = "acrprivate01"
  resource_group_name = local.resource_group
  location            = local.location
  sku                 = "Premium"
  admin_enabled       = false
  public_network_access_enabled = false
  tags = local.tags
}

############################
# AKS (PRIVATE)
############################

resource "azurerm_kubernetes_cluster" "aks" {
  name                = "aks-private-01"
  location            = local.location
  resource_group_name = local.resource_group
  dns_prefix          = "aksprivate"

  private_cluster_enabled = true

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
    outbound_type  = "userDefinedRouting"
  }

  tags = local.tags
}

############################
# AZURE CONTAINER INSTANCE (PRIVATE)
############################

resource "azurerm_container_group" "aci" {
  name                = "aci-private-01"
  location            = local.location
  resource_group_name = local.resource_group
  ip_address_type     = "Private"
  os_type             = "Linux"
  subnet_ids          = [local.aci_subnet_id]

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

############################
# POSTGRESQL FLEXIBLE SERVER (PRIVATE)
############################

resource "azurerm_postgresql_flexible_server" "psql" {
  name                   = "psql-flex-01"
  resource_group_name    = local.resource_group
  location               = local.location
  administrator_login    = "pgadmin"
  administrator_password = "P@ssword12345!"
  version                = "15"

  delegated_subnet_id = local.private_endpoint_subnet_id
  private_dns_zone_id = null

  storage_mb = 32768
  sku_name   = "GP_Standard_D2s_v3"

  tags = local.tags
}

resource "azurerm_postgresql_flexible_server_database" "employee_db" {
  name      = "employee"
  server_id = azurerm_postgresql_flexible_server.psql.id
  collation = "en_US.utf8"
  charset   = "UTF8"
}

############################
# KEY VAULT (PRIVATE)
############################

resource "azurerm_key_vault" "kv" {
  name                        = "kv-private-01"
  location                    = local.location
  resource_group_name         = local.resource_group
  tenant_id                   = data.azurerm_subscription.current.tenant_id
  sku_name                    = "standard"
  public_network_access_enabled = false

  soft_delete_retention_days = 7
  purge_protection_enabled  = true

  tags = local.tags
}
