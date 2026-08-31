locals {
  role_name     = var.agent_name
  role_path     = "/balkanid-agent-lifecycle/"
  use_classic   = var.agent_backend == "classic"
  use_agentcore = var.agent_backend == "agentcore"
  # AgentCore harness names allow alphanumeric and underscores only.
  harness_name = replace(var.agent_name, "-", "_")
}

# Single IAM role for both backends — trust/policy update in place when switching
# agent_backend, avoiding EntityAlreadyExists on the shared role name.
moved {
  from = aws_iam_role.agentcore
  to   = aws_iam_role.execution
}

moved {
  from = aws_iam_role.bedrock_classic
  to   = aws_iam_role.execution
}

moved {
  from = aws_iam_role_policy.agentcore_invoke
  to   = aws_iam_role_policy.invoke
}

moved {
  from = aws_iam_role_policy.bedrock_classic_invoke
  to   = aws_iam_role_policy.invoke
}

resource "aws_iam_role" "execution" {
  count = 1
  name  = local.role_name
  path  = local.role_path

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      local.use_classic ? {
        Effect = "Allow"
        Principal = {
          Service = "bedrock.amazonaws.com"
        }
        Action = "sts:AssumeRole"
        Condition = {
          StringEquals = {
            "aws:SourceAccount" = var.aws_account_id
          }
        }
        } : {
        Effect = "Allow"
        Principal = {
          Service = "bedrock-agentcore.amazonaws.com"
        }
        Action = "sts:AssumeRole"
        Condition = {
          StringEquals = {
            "aws:SourceAccount" = var.aws_account_id
          }
          ArnLike = {
            "aws:SourceArn" = "arn:aws:bedrock-agentcore:${var.aws_region}:${var.aws_account_id}:*"
          }
        }
      }
    ]
  })
}

resource "aws_iam_role_policy" "invoke" {
  count = 1
  name  = "invoke-foundation-model"
  role  = aws_iam_role.execution[0].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = local.use_classic ? [
      {
        Effect   = "Allow"
        Action   = ["bedrock:InvokeModel", "bedrock:InvokeModelWithResponseStream"]
        Resource = "*"
      }
      ] : [
      {
        Effect = "Allow"
        Action = [
          "bedrock:InvokeModel",
          "bedrock:InvokeModelWithResponseStream",
          "bedrock:Converse",
          "bedrock:ConverseStream",
        ]
        Resource = "*"
      },
      {
        Effect = "Allow"
        Action = [
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents",
        ]
        Resource = "*"
      }
    ]
  })
}

resource "aws_bedrockagent_agent" "this" {
  count                       = local.use_classic ? 1 : 0
  agent_name                  = var.agent_name
  agent_resource_role_arn     = aws_iam_role.execution[0].arn
  foundation_model            = var.foundation_model
  instruction                 = var.agent_instruction
  idle_session_ttl_in_seconds = 600

  depends_on = [aws_iam_role_policy.invoke]
}

resource "aws_bedrockagentcore_harness" "this" {
  count              = local.use_agentcore ? 1 : 0
  harness_name       = local.harness_name
  execution_role_arn = aws_iam_role.execution[0].arn

  model {
    bedrock_model_config {
      model_id = var.foundation_model
    }
  }

  system_prompt {
    text = var.agent_instruction
  }

  depends_on = [aws_iam_role_policy.invoke]
}
