terraform {
  required_version = ">= 1.10"

  # State lives in HCP Terraform; the workspace runs the plan and the apply (Remote execution),
  # with short-lived AWS credentials from the OIDC role (see docs/lab7-migration.md, step 1).
  cloud {
    organization = "ooad-marichka-chicheri"

    workspaces {
      name = "new-project-dev"
    }
  }

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
    archive = {
      source  = "hashicorp/archive"
      version = "~> 2.7"
    }
  }
}

provider "aws" {
  region = var.region

  # Lab 4's rule: every resource carries PROJECT_NAME. Resources created by CloudFormation
  # already have this tag, so adopting them does not change their tags.
  default_tags {
    tags = {
      PROJECT_NAME = var.project_name
    }
  }
}

data "aws_caller_identity" "current" {}
