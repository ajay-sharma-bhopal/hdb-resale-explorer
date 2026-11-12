mock_data "aws_availability_zones" {
  defaults = {
    names = ["ap-southeast-1a", "ap-southeast-1b", "ap-southeast-1c"]
  }
}
mock_data "aws_caller_identity" {
  defaults = { account_id = "111111111111" }
}
mock_data "aws_ssm_parameter" {
  defaults = { value = "ami-0123456789abcdef0" }
}
mock_data "aws_vpc" {
  defaults = { cidr_block = "10.20.0.0/16" }
}
mock_data "aws_partition" {
  defaults = { partition = "aws" }
}
mock_data "aws_region" {
  defaults = { name = "ap-southeast-1" }
}
mock_data "aws_elb_service_account" {
  defaults = { arn = "arn:aws:iam::114774131450:root" }
}
mock_data "aws_iam_policy_document" {
  defaults = { json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}" }
}
mock_resource "aws_db_instance" {
  defaults = {
    master_user_secret = [{ secret_arn = "arn:aws:secretsmanager:ap-southeast-1:111111111111:secret:rds-db-credentials", kms_key_id = "k", secret_status = "active" }]
    address            = "db.internal"
  }
}
mock_resource "aws_kms_key" {
  defaults = { arn = "arn:aws:kms:ap-southeast-1:111111111111:key/00000000-0000-0000-0000-000000000000" }
}
mock_resource "aws_lb" {
  defaults = { arn = "arn:aws:elasticloadbalancing:ap-southeast-1:111111111111:loadbalancer/app/x/y", arn_suffix = "app/x/y" }
}
mock_resource "aws_lb_target_group" {
  defaults = { arn = "arn:aws:elasticloadbalancing:ap-southeast-1:111111111111:targetgroup/x/y", arn_suffix = "targetgroup/x/y" }
}
mock_resource "aws_s3_bucket" {
  defaults = { arn = "arn:aws:s3:::alb-logs" }
}
mock_resource "aws_cloudwatch_log_group" {
  defaults = { arn = "arn:aws:logs:ap-southeast-1:111111111111:log-group:x" }
}
mock_resource "aws_sns_topic" {
  defaults = { arn = "arn:aws:sns:ap-southeast-1:111111111111:alarms" }
}
mock_resource "aws_iam_role" {
  defaults = { arn = "arn:aws:iam::111111111111:role/x" }
}
mock_resource "aws_wafv2_web_acl" {
  defaults = { arn = "arn:aws:wafv2:ap-southeast-1:111111111111:regional/webacl/x/y" }
}
