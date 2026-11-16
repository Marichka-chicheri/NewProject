terraform {
  required_version = ">= 1.10"

  # A third state, separate from infra/ (AWS) and gcp/: a mistake here cannot plan a change to
  # Cognito, and `terraform destroy` here removes only Azure. Execution mode Local: HCP Terraform
  # keeps the state and the lock, the plan and apply run on the laptop with `az login`.
  cloud {
    organization = "ooad-marichka-chicheri"

    workspaces {
      name = "new-project-azure"
    }
  }

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.7"
    }
  }
}

# Authenticates through the Azure CLI (`az login`): a short-lived token, no client secret, no key.
provider "azurerm" {
  subscription_id = var.subscription_id

  # Azure for Students cannot register every resource provider; the ones used here are
  # registered by hand in the README (az provider register), not by Terraform.
  resource_provider_registrations = "none"

  features {
    key_vault {
      purge_soft_delete_on_destroy = true
    }
  }
}

data "azurerm_client_config" "current" {}

locals {
  tags = { PROJECT_NAME = var.project_name }
  # Names that must be globally unique get a stable suffix from the subscription.
  suffix = substr(md5(var.subscription_id), 0, 6)
}
