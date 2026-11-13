variable "project" {
  description = "Short project identifier used in resource names."
  type        = string
  default     = "hdbresale"

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{2,15}$", var.project))
    error_message = "project must be 3-16 chars, lowercase letters, digits or hyphens."
  }
}

variable "environment" {
  description = "OutSystems environment this stack hosts (one stack per environment)."
  type        = string

  validation {
    condition     = contains(["lifetime", "dev", "test", "prod"], var.environment)
    error_message = "environment must be one of lifetime, dev, test, prod."
  }
}

variable "region" {
  description = "AWS region. ap-southeast-1 (Singapore) by default for data residency."
  type        = string
  default     = "ap-southeast-1"
}

variable "owner" {
  description = "Owning team, used for tagging and cost allocation."
  type        = string
  default     = "hdbresale-team"
}

variable "data_classification" {
  description = "Data classification tag (e.g. Official-Open, Restricted, Sensitive-Normal)."
  type        = string
  default     = "Official-Open"
}

# ---------------------------------------------------------------- network ---

variable "vpc_cidr" {
  description = "CIDR of the environment VPC."
  type        = string
  default     = "10.20.0.0/16"
}

variable "az_count" {
  description = "Number of availability zones to span (>= 2 for HA)."
  type        = number
  default     = 2

  validation {
    condition     = var.az_count >= 2 && var.az_count <= 3
    error_message = "az_count must be 2 or 3."
  }
}

variable "single_nat_gateway" {
  description = "Use one NAT gateway for all AZs (cheaper, not AZ-resilient). Use false in prod."
  type        = bool
  default     = true
}

variable "allowed_ingress_cidrs" {
  description = "CIDRs allowed to reach the public HTTPS listener. Restrict for non-prod (e.g. agency VPN)."
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

# ----------------------------------------------------------------- compute ---

variable "controller_instance_type" {
  description = "Instance type of the Deployment Controller server (also hosts RabbitMQ for cache invalidation)."
  type        = string
  default     = "m6i.xlarge"
}

variable "frontend_instance_type" {
  description = "Instance type of the front-end servers."
  type        = string
  default     = "m6i.xlarge"
}

variable "frontend_count" {
  description = "Number of front-end servers behind the load balancer (in addition to the controller). Use >= 2 in prod."
  type        = number
  default     = 1

  validation {
    condition     = var.frontend_count >= 0 && var.frontend_count <= 10
    error_message = "frontend_count must be between 0 and 10."
  }
}

variable "root_volume_size_gb" {
  description = "Root EBS volume size for OutSystems servers."
  type        = number
  default     = 150
}

variable "windows_ami_ssm_parameter" {
  description = "SSM public parameter resolving to the Windows Server AMI supported by the OutSystems Platform Server version in use."
  type        = string
  default     = "/aws/service/ami-windows-latest/Windows_Server-2022-English-Full-Base"
}

variable "outsystems_version" {
  description = "OutSystems Platform Server version to install (must match an installer in the installer bucket)."
  type        = string
  default     = "11.31.0"
}

variable "installer_bucket" {
  description = "Existing private S3 bucket holding the OutSystems installers (PlatformServer-<version>.exe, DevelopmentEnvironment is not needed on servers)."
  type        = string
}

# ---------------------------------------------------------------- database ---

variable "db_engine" {
  description = "RDS SQL Server edition: sqlserver-se (Standard, Multi-AZ capable) or sqlserver-ex (Express, dev only)."
  type        = string
  default     = "sqlserver-se"

  validation {
    condition     = contains(["sqlserver-se", "sqlserver-ee", "sqlserver-ex", "sqlserver-web"], var.db_engine)
    error_message = "db_engine must be an RDS SQL Server engine."
  }
}

variable "db_engine_version" {
  description = "RDS SQL Server engine version (SQL Server 2022)."
  type        = string
  default     = "16.00.4135.4.v1"
}

variable "db_instance_class" {
  description = "RDS instance class."
  type        = string
  default     = "db.m6i.large"
}

variable "db_allocated_storage_gb" {
  description = "Initial allocated storage for RDS (GB)."
  type        = number
  default     = 200
}

variable "db_max_allocated_storage_gb" {
  description = "Storage autoscaling ceiling for RDS (GB)."
  type        = number
  default     = 1000
}

variable "db_multi_az" {
  description = "Multi-AZ RDS deployment (synchronous standby). Required in prod."
  type        = bool
  default     = false

  # Cross-variable validation needs Terraform >= 1.9.
  validation {
    condition     = !var.db_multi_az || contains(["sqlserver-se", "sqlserver-ee"], var.db_engine)
    error_message = "RDS SQL Server Multi-AZ requires sqlserver-se or sqlserver-ee (not Express or Web)."
  }
}

variable "db_backup_retention_days" {
  description = "Automated backup retention (days)."
  type        = number
  default     = 7

  validation {
    condition     = var.db_backup_retention_days >= 1 && var.db_backup_retention_days <= 35
    error_message = "db_backup_retention_days must be between 1 and 35."
  }
}

variable "db_deletion_protection" {
  description = "Protect the RDS instance from deletion."
  type        = bool
  default     = true
}

# ----------------------------------------------------------- edge / domain ---

variable "domain_name" {
  description = "Public hostname of this environment (e.g. hdb-resale.dev.example.gov.sg)."
  type        = string
}

variable "acm_certificate_arn" {
  description = "ACM certificate ARN for domain_name (issued/imported outside this stack)."
  type        = string
}

variable "route53_zone_id" {
  description = "Optional Route 53 hosted zone id; when set an alias record is created for domain_name."
  type        = string
  default     = ""
}

variable "enable_waf" {
  description = "Attach an AWS WAFv2 web ACL (AWS managed rule sets + rate limiting) to the load balancer."
  type        = bool
  default     = true
}

variable "waf_rate_limit_per_5min" {
  description = "Requests per 5 minutes per source IP before WAF blocks."
  type        = number
  default     = 2000
}

variable "health_check_path" {
  description = "Load balancer health check path served by every OutSystems front-end."
  type        = string
  default     = "/server.api/v1/health"
}

# ------------------------------------------------------------ operations ---

variable "log_retention_days" {
  description = "CloudWatch Logs retention (days). Secure default of 1 year; non-prod tfvars may shorten it."
  type        = number
  default     = 365
}

variable "alarm_email" {
  description = "Optional e-mail subscribed to the alarms SNS topic."
  type        = string
  default     = ""
}

variable "backup_retention_days" {
  description = "AWS Backup retention for EC2/EBS recovery points (days)."
  type        = number
  default     = 35
}

variable "patch_window_cron" {
  description = "SSM maintenance window schedule for OS patching (Singapore time)."
  type        = string
  default     = "cron(0 3 ? * SUN *)"
}
