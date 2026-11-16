# Programmatic access for this project without the root key.
#
# 1. aws_iam_user.deployer: the identity whose access key goes into .env and the GitHub
#    secrets. No console password. Its policy (policies/deployer-user.json.tftpl) allows only
#    what `make deploy-*`, `make update-lambdas`, `make report-now` and `make llm-*/parse` call,
#    on resources named ${project_name}-*.
# 2. aws_iam_role.cfn_deployer: the CloudFormation service role. The user may hand stacks to
#    this role (iam:PassRole) but cannot create VPCs, databases or roles itself; CloudFormation
#    does that with the role, only inside stacks named ${project_name}-*.
#
# The access key is NOT created here: the account owner creates it in the console after the
# apply (a key in Terraform state is a key in a file). Apply with the SSO profile, not the
# root key:  aws sso login --profile readcycle && AWS_PROFILE=readcycle terraform apply

variable "deployer_user_name" {
  type    = string
  default = "new-project-deployer"
}

data "aws_caller_identity" "current" {}

locals {
  account_id = data.aws_caller_identity.current.account_id
}

# ------------------------------------------------------------------ the CloudFormation role

resource "aws_iam_role" "cfn_deployer" {
  name        = "${var.project_name}-cfn-deployer"
  description = "Assumed by CloudFormation for the ${var.project_name}-* stacks (make deploy-*)."

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "cloudformation.amazonaws.com" }
      Action    = "sts:AssumeRole"
      Condition = {
        StringEquals = { "aws:SourceAccount" = local.account_id }
        ArnLike = {
          "aws:SourceArn" = "arn:aws:cloudformation:${var.region}:${local.account_id}:stack/${var.project_name}-*/*"
        }
      }
    }]
  })
}

# What the templates create: VPC, subnets, security groups, Aurora, Lambda + URL, log group,
# ECR, S3 + CloudFront, ACM, optional Route 53 records. PowerUserAccess covers them without
# a hand-written list that could miss one action and fail a deploy half-way; IAM is not part
# of PowerUserAccess and is granted below only for roles named ${project_name}-*.
resource "aws_iam_role_policy_attachment" "cfn_deployer_power_user" {
  role       = aws_iam_role.cfn_deployer.name
  policy_arn = "arn:aws:iam::aws:policy/PowerUserAccess"
}

resource "aws_iam_role_policy" "cfn_deployer_scope" {
  name = "project-roles-and-guardrails"
  role = aws_iam_role.cfn_deployer.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "ProjectRolesOnly"
        Effect = "Allow"
        Action = [
          "iam:GetRole", "iam:CreateRole", "iam:DeleteRole", "iam:UpdateRole",
          "iam:UpdateAssumeRolePolicy", "iam:TagRole", "iam:UntagRole",
          "iam:GetRolePolicy", "iam:PutRolePolicy", "iam:DeleteRolePolicy",
          "iam:ListRolePolicies", "iam:ListAttachedRolePolicies", "iam:PassRole",
        ]
        Resource = "arn:aws:iam::${local.account_id}:role/${var.project_name}-*"
      },
      {
        # Only the AWS-managed Lambda policies the templates use: no AdministratorAccess on a
        # role the stack creates.
        Sid      = "AttachOnlyLambdaExecutionPolicies"
        Effect   = "Allow"
        Action   = ["iam:AttachRolePolicy", "iam:DetachRolePolicy"]
        Resource = "arn:aws:iam::${local.account_id}:role/${var.project_name}-*"
        Condition = {
          ArnEquals = {
            "iam:PolicyARN" = [
              "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole",
              "arn:aws:iam::aws:policy/service-role/AWSLambdaVPCAccessExecutionRole",
            ]
          }
        }
      },
      {
        # The project lives in us-east-1 (CloudFront, IAM, Route 53 are global). ReadCycle
        # lives in eu-central-1: this role cannot touch anything there.
        Sid       = "StayInTheProjectRegion"
        Effect    = "Deny"
        NotAction = ["iam:*", "cloudfront:*", "route53:*", "sts:*", "support:*"]
        Resource  = "*"
        Condition = { StringNotEquals = { "aws:RequestedRegion" = var.region } }
      },
      {
        Sid    = "NeverTouchReadCycle"
        Effect = "Deny"
        Action = "*"
        Resource = [
          "arn:aws:s3:::readcycle-*",
          "arn:aws:s3:::readcycle-*/*",
          "arn:aws:iam::${local.account_id}:role/readcycle-*",
          "arn:aws:iam::${local.account_id}:role/aws-reserved/*",
          "arn:aws:iam::${local.account_id}:role/AWSReservedSSO_*",
          "arn:aws:lambda:*:${local.account_id}:function:readcycle-*",
          "arn:aws:dynamodb:*:${local.account_id}:table/readcycle-*",
        ]
      },
    ]
  })
}

# ------------------------------------------------------------------------ the user

resource "aws_iam_user" "deployer" {
  name = var.deployer_user_name
  path = "/apps/"
  # No aws_iam_user_login_profile: no console password, programmatic access only.
}

# A managed policy, not an inline one: inline user policies are capped at 2048 bytes in total,
# managed policies at 6144 (this one is ~3.7 KB).
resource "aws_iam_policy" "deployer" {
  name        = "${var.project_name}-deploy"
  path        = "/apps/"
  description = "What make deploy-*, update-lambdas, report-now and llm-* call, on ${var.project_name}-* resources."

  policy = templatefile("${path.module}/policies/deployer-user.json.tftpl", {
    account_id   = local.account_id
    region       = var.region
    project      = var.project_name
    cfn_role_arn = aws_iam_role.cfn_deployer.arn
  })
}

resource "aws_iam_user_policy_attachment" "deployer" {
  user       = aws_iam_user.deployer.name
  policy_arn = aws_iam_policy.deployer.arn
}

output "deployer_user_arn" {
  value = aws_iam_user.deployer.arn
}

output "cfn_role_arn" {
  description = "Put into .env and GitHub as CFN_ROLE_ARN."
  value       = aws_iam_role.cfn_deployer.arn
}
