output "environment_url" {
  description = "Public URL of the environment (Service Center at /ServiceCenter, apps at /<AppName>)."
  value       = "https://${var.domain_name}"
}

output "alb_dns_name" {
  description = "Load balancer DNS name (CNAME/alias target when Route 53 is managed elsewhere)."
  value       = module.edge.alb_dns_name
}

output "controller_instance_id" {
  description = "Deployment Controller instance id (connect with SSM Session Manager; RDP is not exposed)."
  value       = module.servers.controller_instance_id
}

output "frontend_instance_ids" {
  description = "Front-end instance ids."
  value       = module.servers.frontend_instance_ids
}

output "db_endpoint" {
  description = "RDS SQL Server endpoint used by the Platform Server configuration."
  value       = module.database.address
}

output "db_master_secret_arn" {
  description = "Secrets Manager ARN holding the RDS master credentials (rotated by RDS)."
  value       = module.database.master_user_secret_arn
  sensitive   = true
}

output "alarm_topic_arn" {
  description = "SNS topic receiving operational alarms."
  value       = module.operations.alarm_topic_arn
}
