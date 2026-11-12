# Offline plan-time tests: `terraform init -backend=false && terraform test`
# The AWS provider is mocked, so these verify our configuration logic and the
# security / availability invariants each environment profile must satisfy.

mock_provider "aws" {
  source = "./tests"
}

variables {
  installer_bucket    = "test-installers"
  domain_name         = "app.example.gov.sg"
  acm_certificate_arn = "arn:aws:acm:ap-southeast-1:111111111111:certificate/test"
}

run "prod_is_highly_available_and_hardened" {
  command = plan

  variables {
    environment            = "prod"
    az_count               = 3
    frontend_count         = 3
    single_nat_gateway     = false
    db_multi_az            = true
    db_deletion_protection = true
  }

  assert {
    condition     = module.database.multi_az
    error_message = "Production database must be Multi-AZ."
  }
  assert {
    condition     = module.database.storage_encrypted && !module.database.publicly_accessible
    error_message = "Database must be encrypted at rest and private."
  }
  assert {
    condition     = module.database.deletion_protection
    error_message = "Production database must have deletion protection."
  }
  assert {
    condition     = module.servers.frontend_count == 3 && !module.servers.controller_in_target_group
    error_message = "Production traffic must be served by dedicated front-ends, not the controller."
  }
  assert {
    condition     = module.network.nat_gateway_count == 3
    error_message = "Production must have one NAT gateway per AZ."
  }
  assert {
    condition     = module.servers.imdsv2_required && module.servers.root_volumes_encrypted
    error_message = "All servers must enforce IMDSv2 and encrypt their volumes."
  }
  assert {
    condition     = module.edge.ssl_policy == "ELBSecurityPolicy-TLS13-1-2-2021-06" && module.edge.http_redirects_to_https
    error_message = "Listener must enforce TLS 1.2+ and redirect HTTP to HTTPS."
  }
  assert {
    condition     = module.edge.waf_enabled
    error_message = "WAF must be enabled."
  }
}

run "dev_single_server_serves_traffic" {
  command = plan

  variables {
    environment            = "dev"
    frontend_count         = 0
    db_engine              = "sqlserver-ex"
    db_deletion_protection = false
  }

  assert {
    condition     = module.servers.frontend_count == 0 && module.servers.controller_in_target_group
    error_message = "With no front-ends the controller must be registered in the target group."
  }
  assert {
    condition     = module.network.nat_gateway_count == 1
    error_message = "Non-prod uses a single NAT gateway to save cost."
  }
}

run "express_edition_cannot_be_multi_az" {
  command = plan

  variables {
    environment = "dev"
    db_engine   = "sqlserver-ex"
    db_multi_az = true
  }

  expect_failures = [var.db_multi_az]
}

run "rejects_unknown_environment" {
  command = plan

  variables {
    environment = "staging"
  }

  expect_failures = [var.environment]
}

run "rejects_single_az" {
  command = plan

  variables {
    environment = "dev"
    az_count    = 1
  }

  expect_failures = [var.az_count]
}
