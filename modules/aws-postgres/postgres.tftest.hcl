# Postgres module behaviour.
#
# The assertions target the four settings whose absence turns a database into a
# liability: no encryption, no backups, a public endpoint, or a single AZ in
# production.

mock_provider "aws" {}

variables {
  project     = "predcache"
  environment = "dev"
  vpc_id      = "vpc-00000000000000001"
  subnet_ids  = ["subnet-00000000000000001", "subnet-00000000000000002"]
}

run "storage_is_encrypted_and_not_public" {
  command = apply

  assert {
    condition     = aws_db_instance.this.storage_encrypted == true
    error_message = "storage encryption must be on; it cannot be enabled after creation without a rebuild."
  }

  assert {
    condition     = aws_db_instance.this.publicly_accessible == false
    error_message = "the database must never be publicly accessible."
  }

  assert {
    condition     = aws_db_instance.this.multi_az == false
    error_message = "dev does not need a synchronous standby."
  }
}

run "backups_are_retained" {
  command = apply

  assert {
    condition     = aws_db_instance.this.backup_retention_period >= 1
    error_message = "a database with no backups is not recoverable."
  }

  assert {
    condition     = aws_db_instance.this.copy_tags_to_snapshot == true
    error_message = "tags must be copied to snapshots, or a restored instance is unattributable."
  }
}

run "no_password_is_ever_written_to_state" {
  command = apply

  # manage_master_user_password means RDS owns the credential in Secrets
  # Manager. If this ever flips false, a password arg becomes mandatory and the
  # value lands in Terraform state in plaintext.
  assert {
    condition     = aws_db_instance.this.manage_master_user_password == true
    error_message = "the master password must be managed by RDS, never supplied inline."
  }

  # Note: the computed master_user_secret block is not synthesised by a mock
  # provider, so this asserts the configuration rather than the fabricated
  # output. The output itself is exposed as master_user_secret_arn.
  assert {
    condition     = aws_db_instance.this.password == null
    error_message = "no inline password may be set; that is the only way a credential enters state."
  }
}

run "access_is_granted_by_security_group_not_cidr" {
  command = plan

  variables {
    allowed_security_group_ids = ["sg-0aaaaaaaaaaaaaaaa"]
  }

  assert {
    condition = alltrue([
      for r in tolist(aws_security_group.db.ingress) :
      length(coalesce(r.cidr_blocks, [])) == 0
    ])
    error_message = "database ingress must be granted by security group, never by CIDR block."
  }

  assert {
    condition     = length(tolist(aws_security_group.db.ingress)) == 1
    error_message = "exactly one authorised source was supplied, so exactly one rule should exist."
  }
}

run "connection_logging_is_on" {
  command = apply

  assert {
    condition = anytrue([
      for p in aws_db_parameter_group.this.parameter :
      p.name == "log_connections"
    ])
    error_message = "connection logging must be enabled; without it a connection incident has no trail."
  }
}

run "prod_requires_multi_az" {
  command = plan

  variables {
    environment = "prod"
    multi_az    = false
  }

  expect_failures = [aws_db_instance.this]
}

run "prod_multi_az_is_accepted_when_set" {
  command = apply

  variables {
    environment = "prod"
    multi_az    = true
  }

  assert {
    condition     = aws_db_instance.this.multi_az == true
    error_message = "prod must deploy a synchronous standby."
  }
}

run "rejects_zero_backup_retention" {
  command = plan

  variables {
    backup_retention_days = 0
  }

  expect_failures = [aws_db_instance.this]
}
