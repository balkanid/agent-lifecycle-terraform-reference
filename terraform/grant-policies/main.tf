# Account-wide policies that BalkanID attaches to an agent's role for the length of an approved,
# time-bound grant. Used by both the Bedrock developer-agent guardrails (names must match
# "sensitive_grants" in policies/guardrails.json) and the Kiro reference (names must match the
# "grant" entries in its .kiro/balkanid/guardrails.json; set iam_path = "/balkanid-kiro-agents/").
# Create once per account and IAM path. Each stays inside the agent permissions boundary.

data "aws_iam_policy_document" "secrets_read" {
  statement {
    sid       = "ReadApprovedSecrets"
    actions   = ["secretsmanager:GetSecretValue", "secretsmanager:DescribeSecret"]
    resources = var.secret_arns
  }
  statement {
    sid       = "DecryptViaSecretsAndSsmOnly"
    actions   = ["kms:Decrypt"]
    resources = ["*"]
    condition {
      test     = "StringLike"
      variable = "kms:ViaService"
      values   = ["secretsmanager.*.amazonaws.com", "ssm.*.amazonaws.com"]
    }
  }
  dynamic "statement" {
    for_each = length(var.ssm_parameter_arns) > 0 ? [1] : []
    content {
      sid       = "ReadApprovedParameters"
      actions   = ["ssm:GetParameter", "ssm:GetParameters", "ssm:GetParametersByPath"]
      resources = var.ssm_parameter_arns
    }
  }
}

data "aws_iam_policy_document" "production_read_only" {
  statement {
    sid       = "ReadProductionResources"
    actions   = ["ec2:Describe*", "rds:Describe*", "ecs:Describe*", "ecs:List*", "lambda:Get*", "lambda:List*", "logs:Get*", "logs:FilterLogEvents", "cloudwatch:Get*"]
    resources = ["*"]
  }
}

data "aws_iam_policy_document" "customer_data_read" {
  count = length(var.customer_data_bucket_arns) > 0 ? 1 : 0
  statement {
    sid       = "ReadCustomerDataBuckets"
    actions   = ["s3:GetObject", "s3:ListBucket"]
    resources = concat(var.customer_data_bucket_arns, [for b in var.customer_data_bucket_arns : "${b}/*"])
  }
}

resource "aws_iam_policy" "secrets_read" {
  name        = "BalkanIDAgentSecretsRead"
  path        = var.iam_path
  description = "Time-bound BalkanID grant: read approved secrets."
  policy      = data.aws_iam_policy_document.secrets_read.json
}

resource "aws_iam_policy" "production_read_only" {
  name        = "BalkanIDAgentProductionReadOnly"
  path        = var.iam_path
  description = "Time-bound BalkanID grant: read-only access to production resources."
  policy      = data.aws_iam_policy_document.production_read_only.json
}

resource "aws_iam_policy" "customer_data_read" {
  count       = length(var.customer_data_bucket_arns) > 0 ? 1 : 0
  name        = "BalkanIDAgentCustomerDataRead"
  path        = var.iam_path
  description = "Time-bound BalkanID grant: read customer data buckets."
  policy      = data.aws_iam_policy_document.customer_data_read[0].json
}
