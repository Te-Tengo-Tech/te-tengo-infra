# Role the GitHub Actions deploy workflow assumes through OIDC (no long-lived AWS keys in
# GitHub). It can only open SSH-over-SSM sessions to this instance and manage its own sessions.
# The workflow must use a role-session-name that starts with "<project>-<environment>-deploy-".
locals {
  github_deploy             = var.github_deploy_repository != ""
  github_oidc_provider_arn  = var.github_oidc_provider_arn != "" ? var.github_oidc_provider_arn : one(aws_iam_openid_connect_provider.github[*].arn)
  github_deploy_session_ids = "arn:${local.partition}:ssm:${var.aws_region}:${local.account_id}:session/${local.name}-deploy-*"
}

resource "aws_iam_openid_connect_provider" "github" {
  count = local.github_deploy && var.github_oidc_provider_arn == "" ? 1 : 0

  url            = "https://token.actions.githubusercontent.com"
  client_id_list = ["sts.amazonaws.com"]
}

data "aws_iam_policy_document" "github_deploy_assume_role" {
  count = local.github_deploy ? 1 : 0

  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [local.github_oidc_provider_arn]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:sub"
      values   = ["repo:${var.github_deploy_repository}:environment:${var.github_deploy_environment}"]
    }
  }
}

resource "aws_iam_role" "github_deploy" {
  count = local.github_deploy ? 1 : 0

  name                 = "${local.name}-github-deploy"
  description          = "Assumed by ${var.github_deploy_repository} (environment ${var.github_deploy_environment}) to reach the host through SSM."
  assume_role_policy   = data.aws_iam_policy_document.github_deploy_assume_role[0].json
  max_session_duration = 3600
}

data "aws_iam_policy_document" "github_deploy" {
  count = local.github_deploy ? 1 : 0

  statement {
    sid     = "StartSshSessionOnTheInstance"
    actions = ["ssm:StartSession"]
    resources = [
      aws_instance.app.arn,
      "arn:${local.partition}:ssm:${var.aws_region}::document/AWS-StartSSHSession",
    ]

    condition {
      test     = "BoolIfExists"
      variable = "ssm:SessionDocumentAccessCheck"
      values   = ["true"]
    }
  }

  statement {
    sid       = "ManageOwnDeploySessions"
    actions   = ["ssm:TerminateSession", "ssm:ResumeSession"]
    resources = [local.github_deploy_session_ids]
  }
}

resource "aws_iam_role_policy" "github_deploy" {
  count = local.github_deploy ? 1 : 0

  name   = "ssh-over-ssm-to-${local.name}"
  role   = aws_iam_role.github_deploy[0].id
  policy = data.aws_iam_policy_document.github_deploy[0].json
}
