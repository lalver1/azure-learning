terraform {
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.0"
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

# 9. Storage container for function packages
resource "azurerm_storage_container" "funcpack" {
  name                  = "function-releases"
  storage_account_name  = azurerm_storage_account.funcsa.name
  container_access_type = "private"
}

# 10. Archive the Python Azure Function code
data "archive_file" "funczip" {
  type        = "zip"
  source_dir  = "${path.module}/../../azure_functions"   # assumes ./azure_functions has the function code
  output_path = "${path.module}/../../azure_functions.zip"
}

# 11. Upload zip to blob
resource "azurerm_storage_blob" "funczip" {
  name                   = "azure_functions-${data.archive_file.funczip.output_md5}.zip"
  storage_account_name   = azurerm_storage_account.funcsa.name
  storage_container_name = azurerm_storage_container.funcpack.name
  type                   = "Block"
  source                 = data.archive_file.funczip.output_path
}

# 12. App Service Plan for Function App
resource "azurerm_service_plan" "funcplan" {
  name                = "web-flask-funcplan"
  resource_group_name = azurerm_resource_group.rg.name
  location            = azurerm_resource_group.rg.location
  os_type             = "Linux"
  sku_name            = "Y1" 
}

# 13. Function App running Oryx build during deployment
resource "azurerm_linux_function_app" "funcapp" {
  name                       = "web-flask-funcapp"
  resource_group_name        = azurerm_resource_group.rg.name
  location                   = azurerm_resource_group.rg.location
  service_plan_id            = azurerm_service_plan.funcplan.id
  storage_account_name       = azurerm_storage_account.funcsa.name
  storage_account_access_key = azurerm_storage_account.funcsa.primary_access_key
  functions_extension_version = "~4"

  site_config {
    application_stack {
      docker{
        registry_url = "https://ghcr.io"
        image_name   = "ghcr.io/lalver1/azure-learning"
        image_tag    = "${var.container_tag}"
        }
    }
  }

  app_settings = {
    "SLACK_WEBHOOK_URL"        = data.azurerm_key_vault_secret.slack_webhook_url.value
    "AzureWebJobsStorage"      = azurerm_storage_account.funcsa.primary_connection_string
    "FUNCTIONS_WORKER_RUNTIME" = "python"
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
    service_uri = "https://${azurerm_linux_function_app.funcapp.default_hostname}/api/alert_to_slack?code=${data.azurerm_function_app_host_keys.func_keys.default_function_key}"
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

# 16. Fetch host keys for the function app
data "azurerm_function_app_host_keys" "func_keys" {
  name                = azurerm_linux_function_app.funcapp.name
  resource_group_name = azurerm_resource_group.rg.name
}



