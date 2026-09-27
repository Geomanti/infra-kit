# Network module behaviour, asserted without credentials.
#
# These are the assertions that would be expensive to get wrong in production:
# the private tier must not be internet-routable, and the AZ spread must be real
# rather than nominal.

mock_provider "aws" {
  override_data {
    target = data.aws_availability_zones.available
    values = {
      names = ["eu-central-1a", "eu-central-1b", "eu-central-1c"]
      id    = "eu-central-1"
    }
  }
}

variables {
  project     = "predcache"
  environment = "dev"
  region      = "eu-central-1"
}

run "spreads_across_zones_by_default" {
  command = apply

  variables {
    enable_nat_gateway = false
  }

  assert {
    condition     = length(aws_subnet.public) == 2
    error_message = "the default deployment must span two AZs; one AZ is a single point of failure."
  }

  assert {
    condition     = length(aws_subnet.private) == 2
    error_message = "private subnets must be created per AZ alongside the public ones."
  }

  assert {
    condition     = aws_subnet.public[0].availability_zone != aws_subnet.public[1].availability_zone
    error_message = "the two public subnets must land in different AZs, not the same one twice."
  }
}

run "private_subnets_are_not_internet_routable" {
  command = apply

  variables {
    enable_nat_gateway = false
  }

  assert {
    condition     = alltrue([for s in aws_subnet.private : s.map_public_ip_on_launch == false])
    error_message = "private subnets must not auto-assign public IPs."
  }

  assert {
    condition     = alltrue([for s in aws_subnet.private : s.tags["Tier"] == "private"])
    error_message = "private subnets must be tagged as such so a reviewer can tell the tiers apart."
  }

  # With no NAT there must be no default route in the private tables at all —
  # a private route table with 0.0.0.0/0 pointing nowhere is worse than absent.
  assert {
    condition     = length(aws_route.private_nat) == 0
    error_message = "no NAT gateway was requested, so no private default route should exist."
  }
}

run "provisions_one_nat_by_default_when_egress_is_enabled" {
  command = apply

  variables {
    enable_nat_gateway = true
    single_nat_gateway = true
  }

  assert {
    condition     = length(aws_nat_gateway.this) == 1
    error_message = "single_nat_gateway must provision exactly one NAT gateway."
  }

  assert {
    condition     = alltrue([for r in aws_route.private_nat : r.nat_gateway_id == aws_nat_gateway.this[0].id])
    error_message = "with a single shared NAT every private route must point at it."
  }
}

run "provisions_one_nat_per_az_when_asked" {
  command = apply

  variables {
    enable_nat_gateway = true
    single_nat_gateway = false
  }

  assert {
    condition     = length(aws_nat_gateway.this) == 2
    error_message = "one NAT per AZ must be provisioned when single_nat_gateway is false."
  }

  # Per-AZ NAT is the setting that survives an AZ failure; assert the routes
  # actually differ rather than all pointing at the first gateway.
  assert {
    condition     = aws_route.private_nat[0].nat_gateway_id != aws_route.private_nat[1].nat_gateway_id
    error_message = "each private route table must egress through its own AZ's NAT gateway."
  }
}

run "rejects_a_single_az_deployment" {
  command = plan

  variables {
    az_count           = 1
    enable_nat_gateway = false
  }

  expect_failures = [var.az_count]
}

run "rejects_an_invalid_vpc_cidr" {
  command = plan

  variables {
    vpc_cidr           = "not-a-cidr"
    enable_nat_gateway = false
  }

  expect_failures = [var.vpc_cidr]
}
