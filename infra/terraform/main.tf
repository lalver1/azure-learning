terraform {
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.0"
    }
  }
  backend "azurerm" {
    resource_group_name  = "rg-aca-web"
    storage_account_name = "salalver1al"
    container_name       = "tfstate"
    key                  = "terraform.tfstate"
  }
}

provider "azurerm" {
  features {}
  subscription_id = var.subscription_id
}

# Get information about the current Azure client (logged-in identity)
data "azurerm_client_config" "current" {}

locals {
  is_prod    = terraform.workspace == "default"
  is_test    = terraform.workspace == "test"
  is_dev     = !(local.is_prod || local.is_test)
  env_name   = local.is_prod ? "prod" : terraform.workspace
  env_letter = upper(substr(local.env_name, 0, 1))
}

# 1. Resource group
# Initially created manually to hold the tfstate storage account
# Import once before the first terraform apply
# But later suffixed the name with the environment
resource "azurerm_resource_group" "main" {
  name     = "rg-aca-web-${local.env_letter}"
  location = "West US"
}

# 2. Storage Account
# Initially created manually to hold the tfstate file
# Import once before the first terraform apply
resource "azurerm_storage_account" "main" {
  name                          = "salalver1al${lower(local.env_letter)}"
  resource_group_name           = azurerm_resource_group.main.name
  location                      = azurerm_resource_group.main.location
  account_tier                  = "Standard"
  account_replication_type      = "LRS"
  public_network_access_enabled = true

  blob_properties {
    last_access_time_enabled = true
    versioning_enabled       = true

    container_delete_retention_policy {
      days = 7
    }

    delete_retention_policy {
      days = 7
    }
  }

  dynamic "network_rules" {
    for_each = var.enable_storage_firewall ? [1] : []
    content {

      default_action = "Deny"
      bypass         = ["AzureServices"]

    }
  }
}

# 3. Container App Environment
resource "azurerm_container_app_environment" "main" {
  name                = "web-aca-env-${local.env_letter}"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
}

# 4. Container App - Web
resource "azurerm_container_app" "web" {
  name                         = "aca-web-${lower(local.env_letter)}"
  container_app_environment_id = azurerm_container_app_environment.main.id
  resource_group_name          = azurerm_resource_group.main.name
  revision_mode                = "Single"

  ingress {
    external_enabled = true
    target_port      = 50505 # match the port the Flask app listens on
    traffic_weight {
      latest_revision = true
      percentage      = 100
    }
    transport = "auto"
  }

  template {
    container {
      name   = "web"
      image  = "ghcr.io/lalver1/azure-learning:${var.container_tag}"
      cpu    = 0.5
      memory = "1.0Gi"

      env {
        name  = "APPLICATIONINSIGHTS_CONNECTION_STRING"
        value = azurerm_application_insights.main.connection_string
      }
    }
  }
}

# 5. Log Analytics Workspace (needed for App Insights)
resource "azurerm_log_analytics_workspace" "main" {
  name                = "law-web-${local.env_letter}"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  sku                 = "PerGB2018"
  retention_in_days   = 30
}

# 6. Application Insights
resource "azurerm_application_insights" "main" {
  name                = "appi-web-${local.env_letter}"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  application_type    = "web"
  workspace_id        = azurerm_log_analytics_workspace.main.id
}

# 7. Key Vault
resource "azurerm_key_vault" "main" {
  name                = "kv-al-${local.env_letter}"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  tenant_id           = data.azurerm_client_config.current.tenant_id
  sku_name            = "standard"

  access_policy {
    tenant_id = data.azurerm_client_config.current.tenant_id
    object_id = data.azurerm_client_config.current.object_id

    secret_permissions = [
      "Get",
      "List",
      "Set",
      "Delete",
      "Purge",
      "Recover",
      "Backup",
      "Restore"
    ]

    key_permissions = [
      "Get", "List", "Create", "Delete", "Purge", "Recover", "Backup", "Restore"
    ]
  }
}
