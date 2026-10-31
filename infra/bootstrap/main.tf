# The one piece that has to exist before HCP Terraform can do anything: an IAM role that HCP
# Terraform runs may assume through OIDC, and the OIDC identity provider that vouches for them.
# Applied once, from the laptop, with your own AWS credentials; its state stays local (it is in
# .gitignore). Everything else is created by HCP Terraform with this role.
#
# If you already did this in the Lab 7 walkthrough (Part 1, Step 7), do not apply it again:
# reuse that role and only add the new workspace to its trust policy.

terraform {
  required_version = ">= 1.10"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }
}

variable "tfc_organization" {
  type        = string
  description = "Your HCP Terraform organization, e.g. ooad-marichka-chicheri."
}

variable "workspaces" {
  type        = list(string)
  default     = ["new-project-dev"]
  description = "The only workspaces allowed to assume the role."
}

variable "region" {
  type    = string
  default = "us-east-1"
}

variable "project_name" {
  type    = string
  default = "new-project"
}

provider "aws" {
  region = var.region

  default_tags {
    tags = {
      PROJECT_NAME = var.project_name
    }
  }
}

resource "aws_iam_openid_connect_provider" "tfc" {
  url            = "https://app.terraform.io"
  client_id_list = ["aws.workload.identity"]
}

resource "aws_iam_role" "tfc" {
  name = "hcp-terraform-${var.tfc_organization}"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Federated = aws_iam_openid_connect_provider.tfc.arn }
      Action    = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = { "app.terraform.io:aud" = "aws.workload.identity" }
        # One organization, only the listed workspaces, any project and run phase.
        StringLike = {
          "app.terraform.io:sub" = [
            for w in var.workspaces : "organization:${var.tfc_organization}:project:*:workspace:${w}:run_phase:*"
          ]
        }
      }
    }]
  })
}

# For the class project. A real team narrows this to the services the workspace manages.
resource "aws_iam_role_policy_attachment" "tfc" {
  role       = aws_iam_role.tfc.name
  policy_arn = "arn:aws:iam::aws:policy/AdministratorAccess"
}

output "role_arn" {
  value = aws_iam_role.tfc.arn
}
