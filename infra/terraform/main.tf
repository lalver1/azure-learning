terraform {
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 3.100"
    }
  }
  backend "azurerm" {
        resource_group_name  = "web-flask-aca-rg"
        storage_account_name = "lalver1azurelearning"
        container_name       = "tfstate"
        key                  = "web-aca-app.tfstate"
      }
}

provider "azurerm" {
  features {}
}

# Get information about the current Azure client (logged-in identity)
data "azurerm_client_config" "current" {}

# 1. Resource group
resource "azurerm_resource_group" "rg" {
  name     = "web-flask-aca-rg"
  location = "South Central US"
}

# 2. Container App Environment
resource "azurerm_container_app_environment" "env" {
  name                = "web-aca-env"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
}

# 3. Container App
resource "azurerm_container_app" "app" {
  name                         = "web-aca-app"
  container_app_environment_id = azurerm_container_app_environment.env.id
  resource_group_name          = azurerm_resource_group.rg.name
  revision_mode                = "Single"

  ingress {
    external_enabled = true
    target_port      = 50505 # match the port your Flask app listens on
    traffic_weight {
      revision_suffix = var.container_tag
      percentage=100
      }
    transport        = "auto"
  }

  template {
    container {
      name   = "flask-app"
      image  = "ghcr.io/lalver1/azure-learning:${var.container_tag}"
      cpu    = 0.5
      memory = "1.0Gi"
    
    env {
        name  = "APPLICATIONINSIGHTS_CONNECTION_STRING"
        value = azurerm_application_insights.appi.connection_string
      }
    }
  }
}

# 4. Log Analytics Workspace (needed for App Insights)
resource "azurerm_log_analytics_workspace" "law" {
  name                = "web-flask-law"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
  sku                 = "PerGB2018"
  retention_in_days   = 30
}

# 5. Application Insights
resource "azurerm_application_insights" "appi" {
  name                = "web-flask-appi"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
  application_type    = "web"
  workspace_id        = azurerm_log_analytics_workspace.law.id
}

# 6. Key Vault
resource "azurerm_key_vault" "kv" {
  name                        = "webflaskkv"
  location                    = azurerm_resource_group.rg.location
  resource_group_name         = azurerm_resource_group.rg.name
  tenant_id                   = data.azurerm_client_config.current.tenant_id
  sku_name                    = "standard"

  soft_delete_retention_days  = 7
  purge_protection_enabled    = true

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
  }
}

# 7. Key Vault Secret
data "azurerm_key_vault_secret" "slack_webhook_url" {
  name         = "slack-webhook-url"
  key_vault_id = azurerm_key_vault.kv.id
}