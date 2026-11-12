variable "name" { type = string }
variable "vpc_id" { type = string }
variable "data_subnet_ids" { type = list(string) }
variable "app_security_group_id" { type = string }
variable "kms_key_arn" { type = string }
variable "engine" { type = string }
variable "engine_version" { type = string }
variable "instance_class" { type = string }
variable "allocated_storage_gb" { type = number }
variable "max_allocated_storage_gb" { type = number }
variable "multi_az" { type = bool }
variable "backup_retention_days" { type = number }
variable "deletion_protection" { type = bool }

locals {
  # e.g. sqlserver-se + 16.00.4135.4.v1 -> sqlserver-se-16.0
  parameter_family = "${var.engine}-${tonumber(split(".", var.engine_version)[0])}.0"
}

resource "aws_db_subnet_group" "this" {
  name       = var.name
  subnet_ids = var.data_subnet_ids
}

resource "aws_security_group" "db" {
  name        = "${var.name}-db"
  description = "RDS SQL Server - only reachable from the OutSystems servers"
  vpc_id      = var.vpc_id
  tags        = { Name = "${var.name}-db" }
}

resource "aws_vpc_security_group_ingress_rule" "sql_from_servers" {
  security_group_id            = aws_security_group.db.id
  description                  = "SQL Server from OutSystems servers"
  ip_protocol                  = "tcp"
  from_port                    = 1433
  to_port                      = 1433
  referenced_security_group_id = var.app_security_group_id
}

resource "aws_db_parameter_group" "this" {
  name        = "${var.name}-sqlserver"
  family      = local.parameter_family
  description = "OutSystems platform database settings"

  # Encrypt every client connection (Platform Server connection strings use Encrypt=True).
  parameter {
    name         = "rds.force_ssl"
    value        = "1"
    apply_method = "pending-reboot"
  }
}

data "aws_iam_policy_document" "monitoring_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["monitoring.rds.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "monitoring" {
  name               = "${var.name}-rds-monitoring"
  assume_role_policy = data.aws_iam_policy_document.monitoring_assume.json
}

resource "aws_iam_role_policy_attachment" "monitoring" {
  role       = aws_iam_role.monitoring.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonRDSEnhancedMonitoringRole"
}

resource "aws_db_instance" "this" {
  identifier     = var.name
  engine         = var.engine
  engine_version = var.engine_version
  license_model  = "license-included"
  instance_class = var.instance_class

  allocated_storage     = var.allocated_storage_gb
  max_allocated_storage = var.max_allocated_storage_gb
  storage_type          = "gp3"
  storage_encrypted     = true
  kms_key_id            = var.kms_key_arn

  username                      = "osadmin"
  manage_master_user_password   = true
  master_user_secret_kms_key_id = var.kms_key_arn

  db_subnet_group_name   = aws_db_subnet_group.this.name
  vpc_security_group_ids = [aws_security_group.db.id]
  parameter_group_name   = aws_db_parameter_group.this.name
  publicly_accessible    = false
  multi_az               = var.multi_az
  port                   = 1433

  backup_retention_period   = var.backup_retention_days
  backup_window             = "17:00-18:00" # 01:00-02:00 SGT
  maintenance_window        = "sun:18:30-sun:19:30"
  copy_tags_to_snapshot     = true
  delete_automated_backups  = false
  deletion_protection       = var.deletion_protection
  skip_final_snapshot       = false
  final_snapshot_identifier = "${var.name}-final"

  auto_minor_version_upgrade      = true
  enabled_cloudwatch_logs_exports = ["error", "agent"]
  monitoring_interval             = 60
  monitoring_role_arn             = aws_iam_role.monitoring.arn

  performance_insights_enabled          = var.engine != "sqlserver-ex"
  performance_insights_kms_key_id       = var.engine != "sqlserver-ex" ? var.kms_key_arn : null
  performance_insights_retention_period = var.engine != "sqlserver-ex" ? 7 : null

  lifecycle {
    precondition {
      condition     = !var.multi_az || contains(["sqlserver-se", "sqlserver-ee"], var.engine)
      error_message = "RDS SQL Server Multi-AZ requires sqlserver-se or sqlserver-ee."
    }
  }
}

output "address" { value = aws_db_instance.this.address }
output "instance_id" { value = aws_db_instance.this.identifier }
output "master_user_secret_arn" { value = aws_db_instance.this.master_user_secret[0].secret_arn }
output "security_group_id" { value = aws_security_group.db.id }
output "multi_az" { value = aws_db_instance.this.multi_az }
output "storage_encrypted" { value = aws_db_instance.this.storage_encrypted }
output "publicly_accessible" { value = aws_db_instance.this.publicly_accessible }
output "deletion_protection" { value = aws_db_instance.this.deletion_protection }
