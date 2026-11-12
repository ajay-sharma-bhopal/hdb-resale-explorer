# One OutSystems 11 (self-managed) environment per stack/state file:
#   lifetime | dev | test | prod
# Each environment = Deployment Controller + N front-ends (Windows/IIS) behind an
# ALB+WAF, backed by a dedicated RDS SQL Server instance, in its own VPC.

locals {
  name = "${var.project}-${var.environment}"

  common_tags = {
    Project            = var.project
    Environment        = var.environment
    Owner              = var.owner
    DataClassification = var.data_classification
    ManagedBy          = "terraform"
    Platform           = "outsystems-11"
  }

  is_prod = var.environment == "prod"
}

data "aws_caller_identity" "current" {}

# Customer-managed key used for EBS, RDS, Secrets, Logs and SNS in this environment.
resource "aws_kms_key" "main" {
  description             = "${local.name} encryption key"
  enable_key_rotation     = true
  deletion_window_in_days = 30
  policy                  = data.aws_iam_policy_document.kms.json
}

resource "aws_kms_alias" "main" {
  name          = "alias/${local.name}"
  target_key_id = aws_kms_key.main.key_id
}

data "aws_iam_policy_document" "kms" {
  statement {
    sid       = "AccountAdmin"
    actions   = ["kms:*"]
    resources = ["*"]
    principals {
      type        = "AWS"
      identifiers = ["arn:aws:iam::${data.aws_caller_identity.current.account_id}:root"]
    }
  }

  statement {
    sid = "AllowCloudWatchLogs"
    actions = [
      "kms:Encrypt", "kms:Decrypt", "kms:ReEncrypt*", "kms:GenerateDataKey*", "kms:DescribeKey",
    ]
    resources = ["*"]
    principals {
      type        = "Service"
      identifiers = ["logs.${var.region}.amazonaws.com"]
    }
  }

  statement {
    sid       = "AllowSNSAndCloudWatchAlarms"
    actions   = ["kms:Decrypt", "kms:GenerateDataKey*"]
    resources = ["*"]
    principals {
      type        = "Service"
      identifiers = ["cloudwatch.amazonaws.com", "sns.amazonaws.com"]
    }
  }
}

module "network" {
  source = "./modules/network"

  name               = local.name
  vpc_cidr           = var.vpc_cidr
  az_count           = var.az_count
  single_nat_gateway = var.single_nat_gateway
  region             = var.region
  kms_key_arn        = aws_kms_key.main.arn
  log_retention_days = var.log_retention_days
}

module "edge" {
  source = "./modules/edge"

  name                    = local.name
  vpc_id                  = module.network.vpc_id
  public_subnet_ids       = module.network.public_subnet_ids
  allowed_ingress_cidrs   = var.allowed_ingress_cidrs
  acm_certificate_arn     = var.acm_certificate_arn
  domain_name             = var.domain_name
  route53_zone_id         = var.route53_zone_id
  health_check_path       = var.health_check_path
  enable_waf              = var.enable_waf
  waf_rate_limit_per_5min = var.waf_rate_limit_per_5min
  deletion_protection     = local.is_prod
  log_retention_days      = var.log_retention_days
  kms_key_arn             = aws_kms_key.main.arn
}

module "servers" {
  source = "./modules/outsystems_servers"

  name                      = local.name
  environment               = var.environment
  region                    = var.region
  vpc_id                    = module.network.vpc_id
  app_subnet_ids            = module.network.app_subnet_ids
  alb_security_group_id     = module.edge.alb_security_group_id
  target_group_arn          = module.edge.target_group_arn
  kms_key_arn               = aws_kms_key.main.arn
  controller_instance_type  = var.controller_instance_type
  frontend_instance_type    = var.frontend_instance_type
  frontend_count            = var.frontend_count
  root_volume_size_gb       = var.root_volume_size_gb
  windows_ami_ssm_parameter = var.windows_ami_ssm_parameter
  outsystems_version        = var.outsystems_version
  installer_bucket          = var.installer_bucket
  db_endpoint               = module.database.address
  db_master_secret_arn      = module.database.master_user_secret_arn
  log_retention_days        = var.log_retention_days
}

module "database" {
  source = "./modules/database"

  name                     = local.name
  vpc_id                   = module.network.vpc_id
  data_subnet_ids          = module.network.data_subnet_ids
  app_security_group_id    = module.servers.servers_security_group_id
  kms_key_arn              = aws_kms_key.main.arn
  engine                   = var.db_engine
  engine_version           = var.db_engine_version
  instance_class           = var.db_instance_class
  allocated_storage_gb     = var.db_allocated_storage_gb
  max_allocated_storage_gb = var.db_max_allocated_storage_gb
  multi_az                 = var.db_multi_az
  backup_retention_days    = var.db_backup_retention_days
  deletion_protection      = var.db_deletion_protection
}

module "operations" {
  source = "./modules/operations"

  name                  = local.name
  kms_key_arn           = aws_kms_key.main.arn
  alarm_email           = var.alarm_email
  alb_arn_suffix        = module.edge.alb_arn_suffix
  target_group_suffix   = module.edge.target_group_arn_suffix
  db_instance_id        = module.database.instance_id
  instance_ids          = module.servers.instance_ids
  backup_retention_days = var.backup_retention_days
  patch_window_cron     = var.patch_window_cron
}
