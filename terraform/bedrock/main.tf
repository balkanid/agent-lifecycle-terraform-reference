locals {
  role_name     = var.agent_name
  role_path     = "/balkanid-agent-lifecycle/"
  use_classic   = var.agent_backend == "classic"
  use_agentcore = var.agent_backend == "agentcore"
  # AgentCore harness names allow alphanumeric and underscores only.
  harness_name = replace(var.agent_name, "-", "_")
}

resource "aws_iam_role" "bedrock_classic" {
  count = local.use_classic ? 1 : 0
  name  = local.role_name
  path  = local.role_path

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
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
      }
    ]
  })
}

resource "aws_iam_role_policy" "bedrock_classic_invoke" {
  count = local.use_classic ? 1 : 0
  name  = "invoke-foundation-model"
  role  = aws_iam_role.bedrock_classic[0].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["bedrock:InvokeModel", "bedrock:InvokeModelWithResponseStream"]
        Resource = "*"
      }
    ]
  })
}

resource "aws_bedrockagent_agent" "this" {
  count                       = local.use_classic ? 1 : 0
  agent_name                  = var.agent_name
  agent_resource_role_arn     = aws_iam_role.bedrock_classic[0].arn
  foundation_model            = var.foundation_model
  instruction                 = var.agent_instruction
  idle_session_ttl_in_seconds = 600

  depends_on = [aws_iam_role_policy.bedrock_classic_invoke]
}

resource "aws_iam_role" "agentcore" {
  count = local.use_agentcore ? 1 : 0
  name  = local.role_name
  path  = local.role_path

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Service = "bedrock-agentcore.amazonaws.com"
        }
        Action = "sts:AssumeRole"
      }
    ]
  })
}

resource "aws_iam_role_policy" "agentcore_invoke" {
  count = local.use_agentcore ? 1 : 0
  name  = "invoke-foundation-model"
  role  = aws_iam_role.agentcore[0].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
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

resource "aws_bedrockagentcore_harness" "this" {
  count              = local.use_agentcore ? 1 : 0
  harness_name       = local.harness_name
  execution_role_arn = aws_iam_role.agentcore[0].arn

  model {
    bedrock_model_config {
      model_id = var.foundation_model
    }
  }

  system_prompt {
    text = var.agent_instruction
  }

  depends_on = [aws_iam_role_policy.agentcore_invoke]
}
