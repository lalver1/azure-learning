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
        resource_group_name  = "rg-aca-web"
        storage_account_name = "salalver1al"
        container_name       = "tfstate"
        key                  = "terraform.tfstate"
      }
}

provider "azurerm" {
  features {}
}

# Get information about the current Azure client (logged-in identity)
data "azurerm_client_config" "current" {}

# 1. Resource group
# Initially created manually to hold the tfstate storage account
# Import once before the first terraform apply
resource "azurerm_resource_group" "main" {
  name     = "rg-aca-web"
  location = "West US"
}

# 2. Storage Account
# Initially created manually to hold the tfstate file
# Import once before the first terraform apply
resource "azurerm_storage_account" "main" {
  name                          = "salalver1al"
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

  network_rules {
    default_action = "Deny"
    bypass         = ["AzureServices"]
  }
}

# 3. Container App Environment
resource "azurerm_container_app_environment" "main" {
  name                = "web-aca-env"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
}

# 4. Container App - Web
resource "azurerm_container_app" "web" {
  name                         = "aca-web"
  container_app_environment_id = azurerm_container_app_environment.main.id
  resource_group_name          = azurerm_resource_group.main.name
  revision_mode                = "Single"

  ingress {
    external_enabled = true
    target_port      = 50505 # match the port the Flask app listens on
    traffic_weight {
      latest_revision = true
      percentage=100
      }
    transport        = "auto"
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
  name                = "law-web"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  sku                 = "PerGB2018"
  retention_in_days   = 30
}

# 6. Application Insights
resource "azurerm_application_insights" "main" {
  name                = "appi-web"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  application_type    = "web"
  workspace_id        = azurerm_log_analytics_workspace.main.id
}

# 7. Key Vault
resource "azurerm_key_vault" "main" {
  name                        = "kv-al"
  location                    = azurerm_resource_group.main.location
  resource_group_name         = azurerm_resource_group.main.name
  tenant_id                   = data.azurerm_client_config.current.tenant_id
  sku_name                    = "standard"

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

# 8. Key Vault Secret
data "azurerm_key_vault_secret" "slack_webhook_url" {
  name         = "slack-webhook-url"
  key_vault_id = azurerm_key_vault.main.id
}

# 9. A secure, random key for the Azure Functions' webhook URL
resource "random_string" "function_key" {
  length  = 32
  special = false
}

# 10. Container App - Azure Functions
resource "azurerm_container_app" "funcs" {
  name                         = "aca-funcs"
  container_app_environment_id = azurerm_container_app_environment.main.id
  resource_group_name          = azurerm_resource_group.main.name
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
    value = azurerm_application_insights_api_key.main.api_key
  }

  template {
    container {
      name   = "functions"
      image  = "ghcr.io/lalver1/azure-functions:${var.container_tag}"
      cpu    = 0.25
      memory = "0.5Gi"

      env {
        name  = "APPLICATIONINSIGHTS_CONNECTION_STRING"
        value = azurerm_application_insights.main.connection_string
      }
      env {
        name  = "AzureWebJobsStorage"
        value = azurerm_storage_account.main.primary_connection_string
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

# 11. Action Group that posts to the Functions App
resource "azurerm_monitor_action_group" "main" {
  name                = "ag-funcapp-webhook"
  resource_group_name = azurerm_resource_group.main.name
  short_name          = "funcag"

  webhook_receiver {
    name        = "funcapp-webhook"
    service_uri = "https://${azurerm_container_app.funcs.ingress[0].fqdn}/api/alert_to_slack?CODE=${random_string.function_key.result}"
  }
}

# 12. Log Search alert rule
resource "azurerm_monitor_scheduled_query_rules_alert_v2" "main" {
  name                = "qr-error"
  resource_group_name = azurerm_resource_group.main.name
  location            = azurerm_resource_group.main.location
  scopes              = [azurerm_application_insights.main.id]

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
    action_groups = [azurerm_monitor_action_group.main.id]
    custom_properties = {
      subject = "🚨 Application Error"
    }
  }

  lifecycle {
    ignore_changes = [tags]
  }
}

# 13. Create an API key for querying Application Insights data
resource "azurerm_application_insights_api_key" "main" {
  name                    = "api-query-key-funcs"
  application_insights_id = azurerm_application_insights.main.id

  read_permissions = [
    "search",
  ]
}