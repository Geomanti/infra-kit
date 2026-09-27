output "vpc_id" {
  description = "The VPC everything else attaches to."
  value       = aws_vpc.this.id
}

output "public_subnet_ids" {
  description = "Subnets that can carry a load balancer."
  value       = aws_subnet.public[*].id
}

output "private_subnet_ids" {
  description = "Subnets for compute, database and cache tiers with no inbound internet route."
  value       = aws_subnet.private[*].id
}

output "availability_zones" {
  description = "The AZs actually used, so callers do not have to re-derive them."
  value       = local.azs
}

output "nat_gateway_ids" {
  description = "NAT gateways provisioned (empty when egress is disabled)."
  value       = aws_nat_gateway.this[*].id
}

output "internet_gateway_id" {
  description = "Internet gateway id — present only on the public path."
  value       = aws_internet_gateway.this.id
}

output "public_route_table_id" {
  description = "Route table carrying the public default route."
  value       = aws_route_table.public.id
}

output "private_route_table_ids" {
  description = "Per-AZ private route tables."
  value       = aws_route_table.private[*].id
}

output "tags" {
  description = "Tags applied to the network resources."
  value       = local.tags
}
