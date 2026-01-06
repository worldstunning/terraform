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
    random = {
      source = "hashicorp/random"
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
  resource_group = "rg-1"

  tags = {
    "Business Unit" = "IT"
    "Cost Center"   = "CC-1001"
  }
}

#####################################
# RANDOM SUFFIX (GLOBAL UNIQUENESS)
#####################################

resource "random_string" "suffix" {
  length  = 6
  upper   = false
  special = false
}

#####################################
# RESOURCE GROUP
#####################################

resource "azurerm_resource_group" "rg" {
  name     = local.resource_group
  location = local.location
  tags     = local.tags
}

#####################################
# NETWORKING (VNET + SUBNETS)
#####################################

resource "azurerm_virtual_network" "vnet" {
  name                = "vnet-01"
  location            = local.location
  resource_group_name = azurerm_resource_group.rg.name
  address_space       = ["10.0.0.0/16"]
  tags                = local.tags
}

resource "azurerm_subnet" "aks" {
  name                 = "aks-subnet"
  resource_group_name  = azurerm_resource_group.rg.name
  virtual_network_name = azurerm_virtual_network.vnet.name
  address_prefixes     = ["10.0.1.0/24"]
}

resource "azurerm_subnet" "aci" {
  name                 = "aci-subnet"
  resource_group_name  = azurerm_resource_group.rg.name
  virtual_network_name = azurerm_virtual_network.vnet.name
  address_prefixes     = ["10.0.2.0/24"]
}

resource "azurerm_subnet" "psql" {
  name                 = "psql-subnet"
  resource_group_name  = azurerm_resource_group.rg.name
  virtual_network_name = azurerm_virtual_network.vnet.name
  address_prefixes     = ["10.0.3.0/24"]

  delegation {
    name = "postgres"
    service_delegation {
      name = "Microsoft.DBforPostgreSQL/flexibleServers"
    }
  }
}

#####################################
# AZURE POLICIES
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
    then = { effect = "deny" }
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
        in    = ["centralindia", "southindia"]
      }
    }
    then = { effect = "deny" }
  })
}

resource "azurerm_subscription_policy_assignment" "mandatory_tags" {
  name                 = "mandatory-tags"
  policy_definition_id = azurerm_policy_definition.mandatory_tags.id
  subscription_id      = data.azurerm_subscription.current.id
}

resource "azurerm_subscription_policy_assignment" "allowed_locations" {
  name                 = "allowed-locations"
  policy_definition_id = azurerm_policy_definition.allowed_locations.id
  subscription_id      = data.azurerm_subscription.current.id
}

#####################################
# ACR (PRIVATE)
#####################################

resource "azurerm_container_registry" "acr" {
  name                = "acrprivate${random_string.suffix.result}"
  resource_group_name = azurerm_resource_group.rg.name
  location            = local.location
  sku                 = "Premium"

  admin_enabled                 = false
  public_network_access_enabled = false

  tags = local.tags
}

#####################################
# PRIVATE DNS FOR POSTGRESQL
#####################################

resource "azurerm_private_dns_zone" "psql" {
  name                = "privatelink.postgres.database.azure.com"
  resource_group_name = azurerm_resource_group.rg.name
}

resource "azurerm_private_dns_zone_virtual_network_link" "psql" {
  name                  = "psql-link"
  resource_group_name   = azurerm_resource_group.rg.name
  private_dns_zone_name = azurerm_private_dns_zone.psql.name
  virtual_network_id    = azurerm_virtual_network.vnet.id
}

#####################################
# POSTGRESQL FLEXIBLE SERVER (PRIVATE)
#####################################

resource "azurerm_postgresql_flexible_server" "psql" {
  name                = "psql-flex-01"
  resource_group_name = azurerm_resource_group.rg.name
  location            = local.location

  administrator_login    = "pgadmin"
  administrator_password = "P@ssword12345!"
  version                = "15"

  delegated_subnet_id = azurerm_subnet.psql.id
  private_dns_zone_id = azurerm_private_dns_zone.psql.id

  sku_name   = "GP_Standard_D2s_v3"
  storage_mb = 32768

  tags = local.tags
}

resource "azurerm_postgresql_flexible_server_database" "employee" {
  name      = "employee"
  server_id = azurerm_postgresql_flexible_server.psql.id
  charset   = "UTF8"
  collation = "en_US.utf8"
}

#####################################
# AKS (PRIVATE)
#####################################

resource "azurerm_kubernetes_cluster" "aks" {
  name                = "aks-private-01"
  location            = local.location
  resource_group_name = azurerm_resource_group.rg.name
  dns_prefix          = "aksprivate"

  private_cluster_enabled = true
  private_dns_zone_id     = "System"

  default_node_pool {
    name           = "system"
    node_count     = 2
    vm_size        = "Standard_DS2_v2"
    vnet_subnet_id = azurerm_subnet.aks.id
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
  resource_group_name = azurerm_resource_group.rg.name
  os_type             = "Linux"

  ip_address_type = "Private"
  subnet_ids      = [azurerm_subnet.aci.id]

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
# KEY VAULT (PRIVATE)
#####################################

resource "azurerm_key_vault" "kv" {
  name                = "kvprivate${random_string.suffix.result}"
  location            = local.location
  resource_group_name = azurerm_resource_group.rg.name
  tenant_id           = data.azurerm_subscription.current.tenant_id
  sku_name            = "standard"

  public_network_access_enabled = false
  purge_protection_enabled      = true
  soft_delete_retention_days    = 7

  tags = local.tags
}
