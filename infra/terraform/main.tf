terraform {
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.5"
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
  location = "West US"
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
      latest_revision = true
      # revision_suffix = var.container_tag
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
  name                        = "webflaskkv4"
  location                    = azurerm_resource_group.rg.location
  resource_group_name         = azurerm_resource_group.rg.name
  tenant_id                   = data.azurerm_client_config.current.tenant_id
  sku_name                    = "standard"

  soft_delete_retention_days  = 7

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

# 7. Key Vault Secret
data "azurerm_key_vault_secret" "slack_webhook_url" {
  name         = "slack-webhook-url"
  key_vault_id = azurerm_key_vault.kv.id
}

# 8. Storage Account for Function App (for runtime + code package)
resource "azurerm_storage_account" "funcsa" {
  name                     = "webflaskfuncsa"
  resource_group_name      = azurerm_resource_group.rg.name
  location                 = azurerm_resource_group.rg.location
  account_tier             = "Standard"
  account_replication_type = "LRS"
}

# Generate a secure, random key for the function's webhook URL
resource "random_string" "function_key" {
  length  = 32
  special = false
}

# Deploy the Function App as a container
resource "azurerm_container_app" "func_app_aca" {
  name                         = "web-flask-func-aca"
  container_app_environment_id = azurerm_container_app_environment.env.id
  resource_group_name          = azurerm_resource_group.rg.name
  revision_mode                = "Single"

  # Securely store secrets that will be injected as environment variables
  secret {
    name  = "slack-webhook-url-secret"
    value = data.azurerm_key_vault_secret.slack_webhook_url.value
  }
  secret {
    name  = "function-key-secret"
    value = random_string.function_key.result
  }
  secret {
    name  = "appinsights-api-key-secret"
    value = azurerm_application_insights_api_key.appi_api_key.api_key
  }

  template {
    container {
      name   = "function-app-container"
      image  = "ghcr.io/lalver1/azure-functions:${var.container_tag}"
      cpu    = 0.25
      memory = "0.5Gi"

      env {
        name  = "APPLICATIONINSIGHTS_CONNECTION_STRING"
        value = azurerm_application_insights.appi.connection_string
      }
      env {
        name  = "AzureWebJobsStorage"
        value = azurerm_storage_account.funcsa.primary_connection_string
      }
      env {
        name        = "SLACK_WEBHOOK_URL"
        secret_name = "slack-webhook-url-secret"
      }
      env {
        name        = "AZURE_FUNCTION_KEY"
        secret_name = "function-key-secret"
      }
      env {
        name        = "APPINSIGHTS_API_KEY"
        secret_name = "appinsights-api-key-secret"
      }
    }
    
    min_replicas = 1
    max_replicas = 1
  }

  ingress {
    external_enabled = true
    target_port      = 80
    transport        = "auto"

    traffic_weight {
      percentage      = 100
      latest_revision = true
    }
  }

  identity {
  type = "SystemAssigned"
}
}

# 14. Action Group that posts to your Function App
resource "azurerm_monitor_action_group" "func_webhook" {
  name                = "funcapp-webhook-ag"
  resource_group_name = azurerm_resource_group.rg.name
  short_name          = "funcag"

  webhook_receiver {
    name        = "funcapp-webhook"
    service_uri = "https://${azurerm_container_app.func_app_aca.ingress[0].fqdn}/api/alert_to_slack?CODE=${random_string.function_key.result}"
  }
}

# 15. Log Search alert rule
resource "azurerm_monitor_scheduled_query_rules_alert_v2" "app_error" {
  name                = "web-flask-app-error"
  resource_group_name = azurerm_resource_group.rg.name
  location            = azurerm_resource_group.rg.location
  scopes              = [azurerm_application_insights.appi.id]

  description  = "Alerts when any exception is logged in Application Insights."
  display_name = "Web Flask App Error Alert"
  enabled      = true
  severity     = 2

  evaluation_frequency = "PT5M"
  window_duration      = "PT5M"

  criteria {
    query     = <<-QUERY
      union (exceptions | where type !has "ServiceResponseError"), (traces | where severityLevel >= 3)
    QUERY
    operator  = "GreaterThan"
    threshold = 0
    time_aggregation_method = "Count"

    failing_periods {
      minimum_failing_periods_to_trigger_alert = 1
      number_of_evaluation_periods             = 1
    }
  }

  action {
    action_groups = [azurerm_monitor_action_group.func_webhook.id]
    custom_properties = {
      subject = "🚨 Application Error"
    }
  }

  lifecycle {
    ignore_changes = [tags]
  }
}

# 16. Create an API key for querying Application Insights data
resource "azurerm_application_insights_api_key" "appi_api_key" {
  name                    = "funcapp-api-query-key"
  application_insights_id = azurerm_application_insights.appi.id

  read_permissions = [
    "search",
  ]
}


output "current_function_master_key" {
  value       = random_string.function_key.result
  sensitive   = true
  description = "The current master key for the function app. Use this for testing."
}