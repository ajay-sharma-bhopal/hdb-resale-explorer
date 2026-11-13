environment           = "lifetime"
domain_name           = "lifetime.example.gov.sg"
acm_certificate_arn   = "arn:aws:acm:ap-southeast-1:111111111111:certificate/00000000-0000-0000-0000-000000000004"
installer_bucket      = "hdbresale-outsystems-installers"
allowed_ingress_cidrs = ["10.0.0.0/8"]
vpc_cidr              = "10.10.0.0/16"
frontend_count        = 0
db_multi_az           = false
