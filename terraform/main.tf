locals {
  role_name = var.agent_name
  role_path = "/balkanid-agent-lifecycle/"
}

resource "null_resource" "balkanid_gate" {
  triggers = {
    agent_name = var.agent_name
    # bump to force a new request on re-apply
    run_nonce = timestamp()
  }

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-lc"]
    command     = "python3 \"${path.module}/../scripts/gate.py\""
    environment = {
      BALKANID_PUBLIC_API_URL    = var.balkanid_public_api_url
      API_KEY_ID                 = var.api_key_id
      API_KEY_SECRET             = var.api_key_secret
      BALKANID_AGENT_OWNER_EMAIL = var.agent_owner_email
      INTEGRATION_ID             = var.integration_id
      AGENT_NAME                 = var.agent_name
      AGENT_TYPE                 = var.agent_type
      AGENT_PURPOSE              = var.agent_purpose
      INTENDED_IAM_ROLE_ARN      = var.intended_iam_role_arn
      POLL_SECONDS               = tostring(var.poll_seconds)
      POLL_TIMEOUT_SECONDS       = tostring(var.poll_timeout_seconds)
    }
  }
}

resource "aws_iam_role" "bedrock_agent" {
  count = var.enable_bedrock ? 1 : 0

  name = local.role_name
  path = local.role_path

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
            "aws:SourceAccount" = data.aws_caller_identity.current[0].account_id
          }
        }
      }
    ]
  })

  depends_on = [null_resource.balkanid_gate]
}

resource "aws_iam_role_policy" "bedrock_invoke" {
  count = var.enable_bedrock ? 1 : 0
  name  = "invoke-foundation-model"
  role  = aws_iam_role.bedrock_agent[0].id

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
  count                       = var.enable_bedrock ? 1 : 0
  agent_name                  = var.agent_name
  agent_resource_role_arn     = aws_iam_role.bedrock_agent[0].arn
  foundation_model            = var.foundation_model
  instruction                 = var.agent_instruction
  idle_session_ttl_in_seconds = 600

  depends_on = [aws_iam_role_policy.bedrock_invoke]
}
