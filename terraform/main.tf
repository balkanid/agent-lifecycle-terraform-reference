resource "null_resource" "balkanid_gate" {
  count = var.run_balkanid_gate ? 1 : 0

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
