variable "name" { type = string }
variable "environment" { type = string }
variable "region" { type = string }
variable "vpc_id" { type = string }
variable "app_subnet_ids" { type = list(string) }
variable "alb_security_group_id" { type = string }
variable "target_group_arn" { type = string }
variable "kms_key_arn" { type = string }
variable "controller_instance_type" { type = string }
variable "frontend_instance_type" { type = string }
variable "frontend_count" { type = number }
variable "root_volume_size_gb" { type = number }
variable "windows_ami_ssm_parameter" { type = string }
variable "outsystems_version" { type = string }
variable "installer_bucket" { type = string }
variable "db_endpoint" { type = string }
variable "db_master_secret_arn" { type = string }
variable "log_retention_days" { type = number }

data "aws_ssm_parameter" "windows_ami" {
  name = var.windows_ami_ssm_parameter
}

data "aws_partition" "current" {}

locals {
  # OutSystems 11 inter-server ports (Deployment Controller 12000, Deployment Service 12001,
  # Scheduler 12002, plus 12003-12004 used by platform services) and RabbitMQ for cache invalidation.
  platform_ports = [
    { from = 12000, to = 12004, desc = "OutSystems platform services" },
    { from = 5672, to = 5672, desc = "RabbitMQ cache invalidation" },
    { from = 443, to = 443, desc = "HTTPS between servers" },
    { from = 80, to = 80, desc = "HTTP between servers (redirected to HTTPS by IIS rewrite)" },
  ]

  # In single-server environments (LifeTime, dev) the controller also serves traffic.
  controller_serves_traffic = var.frontend_count == 0
}

# ----------------------------------------------------------- security group ---

resource "aws_security_group" "servers" {
  name        = "${var.name}-servers"
  description = "OutSystems Deployment Controller and front-end servers"
  vpc_id      = var.vpc_id
  tags        = { Name = "${var.name}-servers" }
}

resource "aws_vpc_security_group_ingress_rule" "https_from_alb" {
  security_group_id            = aws_security_group.servers.id
  description                  = "HTTPS from the load balancer"
  ip_protocol                  = "tcp"
  from_port                    = 443
  to_port                      = 443
  referenced_security_group_id = var.alb_security_group_id
}

resource "aws_vpc_security_group_ingress_rule" "intra" {
  for_each                     = { for p in local.platform_ports : "${p.from}-${p.to}" => p }
  security_group_id            = aws_security_group.servers.id
  description                  = each.value.desc
  ip_protocol                  = "tcp"
  from_port                    = each.value.from
  to_port                      = each.value.to
  referenced_security_group_id = aws_security_group.servers.id
}

resource "aws_vpc_security_group_egress_rule" "all" {
  security_group_id = aws_security_group.servers.id
  description       = "Outbound: RDS, VPC endpoints, data.gov.sg and OutSystems services via NAT"
  ip_protocol       = "-1"
  cidr_ipv4         = "0.0.0.0/0"
}

# ---------------------------------------------------------------- IAM role ---

data "aws_iam_policy_document" "assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "servers" {
  name               = "${var.name}-outsystems-server"
  assume_role_policy = data.aws_iam_policy_document.assume.json
}

resource "aws_iam_role_policy_attachment" "ssm" {
  role       = aws_iam_role.servers.name
  policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_role_policy_attachment" "cwagent" {
  role       = aws_iam_role.servers.name
  policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/CloudWatchAgentServerPolicy"
}

data "aws_iam_policy_document" "servers" {
  statement {
    sid       = "ReadInstallers"
    actions   = ["s3:GetObject", "s3:ListBucket"]
    resources = ["arn:${data.aws_partition.current.partition}:s3:::${var.installer_bucket}", "arn:${data.aws_partition.current.partition}:s3:::${var.installer_bucket}/*"]
  }
  statement {
    sid       = "ReadDbSecret"
    actions   = ["secretsmanager:GetSecretValue", "secretsmanager:DescribeSecret"]
    resources = [var.db_master_secret_arn]
  }
  statement {
    sid       = "UseEnvironmentKey"
    actions   = ["kms:Decrypt", "kms:GenerateDataKey"]
    resources = [var.kms_key_arn]
  }
}

resource "aws_iam_role_policy" "servers" {
  name   = "outsystems-server"
  role   = aws_iam_role.servers.id
  policy = data.aws_iam_policy_document.servers.json
}

resource "aws_iam_instance_profile" "servers" {
  name = "${var.name}-outsystems-server"
  role = aws_iam_role.servers.name
}

# ---------------------------------------------------------------- logging ---

resource "aws_cloudwatch_log_group" "servers" {
  for_each          = toset(["iis", "outsystems", "windows-events"])
  name              = "/outsystems/${var.name}/${each.value}"
  retention_in_days = var.log_retention_days
  kms_key_id        = var.kms_key_arn
}

# ---------------------------------------------------------------- servers ---

locals {
  user_data_common = {
    environment        = var.environment
    region             = var.region
    installer_bucket   = var.installer_bucket
    outsystems_version = var.outsystems_version
    db_endpoint        = var.db_endpoint
    db_secret_arn      = var.db_master_secret_arn
    log_group_prefix   = "/outsystems/${var.name}"
  }
}

resource "aws_instance" "controller" {
  ami                    = data.aws_ssm_parameter.windows_ami.value
  instance_type          = var.controller_instance_type
  subnet_id              = var.app_subnet_ids[0]
  vpc_security_group_ids = [aws_security_group.servers.id]
  iam_instance_profile   = aws_iam_instance_profile.servers.name
  ebs_optimized          = true
  monitoring             = true

  metadata_options {
    http_tokens                 = "required" # IMDSv2 only
    http_put_response_hop_limit = 1
    http_endpoint               = "enabled"
  }

  root_block_device {
    volume_type           = "gp3"
    volume_size           = var.root_volume_size_gb
    encrypted             = true
    kms_key_id            = var.kms_key_arn
    delete_on_termination = true
  }

  user_data = templatefile("${path.module}/templates/bootstrap.ps1.tftpl", merge(local.user_data_common, {
    server_role     = "controller"
    controller_host = "localhost"
  }))
  user_data_replace_on_change = false

  tags = {
    Name           = "${var.name}-controller"
    OutSystemsRole = "DeploymentController"
    Backup         = "daily"
    PatchGroup     = var.name
  }

  lifecycle {
    ignore_changes = [ami] # AMI updates are rolled through patching, not replacement
  }
}

resource "aws_instance" "frontend" {
  count                  = var.frontend_count
  ami                    = data.aws_ssm_parameter.windows_ami.value
  instance_type          = var.frontend_instance_type
  subnet_id              = var.app_subnet_ids[(count.index + 1) % length(var.app_subnet_ids)]
  vpc_security_group_ids = [aws_security_group.servers.id]
  iam_instance_profile   = aws_iam_instance_profile.servers.name
  ebs_optimized          = true
  monitoring             = true

  metadata_options {
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
    http_endpoint               = "enabled"
  }

  root_block_device {
    volume_type           = "gp3"
    volume_size           = var.root_volume_size_gb
    encrypted             = true
    kms_key_id            = var.kms_key_arn
    delete_on_termination = true
  }

  user_data = templatefile("${path.module}/templates/bootstrap.ps1.tftpl", merge(local.user_data_common, {
    server_role     = "frontend"
    controller_host = aws_instance.controller.private_ip
  }))

  tags = {
    Name           = "${var.name}-frontend-${count.index + 1}"
    OutSystemsRole = "FrontEnd"
    Backup         = "daily"
    PatchGroup     = var.name
  }

  lifecycle {
    ignore_changes = [ami]
  }
}

resource "aws_lb_target_group_attachment" "frontend" {
  count            = var.frontend_count
  target_group_arn = var.target_group_arn
  target_id        = aws_instance.frontend[count.index].id
  port             = 443
}

resource "aws_lb_target_group_attachment" "controller" {
  count            = local.controller_serves_traffic ? 1 : 0
  target_group_arn = var.target_group_arn
  target_id        = aws_instance.controller.id
  port             = 443
}

output "servers_security_group_id" { value = aws_security_group.servers.id }
output "controller_instance_id" { value = aws_instance.controller.id }
output "frontend_instance_ids" { value = aws_instance.frontend[*].id }
output "instance_ids" { value = concat([aws_instance.controller.id], aws_instance.frontend[*].id) }
output "frontend_count" { value = length(aws_instance.frontend) }
output "controller_in_target_group" { value = length(aws_lb_target_group_attachment.controller) == 1 }
output "imdsv2_required" {
  value = alltrue([for i in concat([aws_instance.controller], aws_instance.frontend) : i.metadata_options[0].http_tokens == "required"])
}
output "root_volumes_encrypted" {
  value = alltrue([for i in concat([aws_instance.controller], aws_instance.frontend) : i.root_block_device[0].encrypted])
}
