# Cache module behaviour.
#
# A cache deployed without an eviction policy or a failover plan is a load
# source waiting for a bad day. These assertions pin both.

mock_provider "aws" {}

variables {
  project     = "predcache"
  environment = "dev"
  vpc_id      = "vpc-00000000000000001"
  subnet_ids  = ["subnet-00000000000000001", "subnet-00000000000000002"]
}

run "eviction_policy_is_always_set" {
  command = plan

  assert {
    condition = anytrue([
      for p in aws_elasticache_parameter_group.this.parameter :
      p.name == "maxmemory-policy" && p.value == "allkeys-lru"
    ])
    error_message = "an eviction policy must be set explicitly; the default is noeviction, which turns a full cache into write errors."
  }
}

run "encryption_is_on_in_transit_and_at_rest" {
  command = plan

  # Compared via tostring(): this provider attribute is modelled as a string in
  # the AWS provider schema, and mock/plan rendering can present it either way.
  # Asserting the readable value keeps the test about the setting, not its type.
  assert {
    condition     = tostring(aws_elasticache_replication_group.this.at_rest_encryption_enabled) == "true"
    error_message = "at-rest encryption must be enabled."
  }

  assert {
    condition     = tostring(aws_elasticache_replication_group.this.transit_encryption_enabled) == "true"
    error_message = "in-transit encryption must be enabled."
  }
}

run "access_is_granted_by_security_group_not_cidr" {
  command = plan

  variables {
    allowed_security_group_ids = ["sg-0aaaaaaaaaaaaaaaa"]
  }

  assert {
    condition = alltrue([
      for r in tolist(aws_security_group.cache.ingress) :
      length(coalesce(r.cidr_blocks, [])) == 0
    ])
    error_message = "cache ingress must be granted by security group, never by CIDR block."
  }
}

run "failover_requires_a_replica" {
  command = plan

  variables {
    automatic_failover = true
    num_cache_clusters = 1
  }

  expect_failures = [aws_elasticache_replication_group.this]
}

run "failover_is_enabled_with_two_nodes" {
  command = apply

  variables {
    automatic_failover = true
    num_cache_clusters = 2
  }

  assert {
    condition     = aws_elasticache_replication_group.this.automatic_failover_enabled == true
    error_message = "with a replica present, automatic failover must be on."
  }

  assert {
    condition     = aws_elasticache_replication_group.this.multi_az_enabled == true
    error_message = "a cross-AZ failover requires multi_az."
  }
}

run "rejects_an_invalid_eviction_policy" {
  command = plan

  variables {
    maxmemory_policy = "delete-everything"
  }

  expect_failures = [var.maxmemory_policy]
}
