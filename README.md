# infra-kit

Declarative infrastructure for a containerised Python service, in two clouds.

Nine composable Terraform modules, two deployable stacks, and a test suite that
runs with **no cloud credentials and no cloud account** — 94 test runs and 182
assertions, green.

```bash
git clone https://github.com/Geomanti/infra-kit
cd infra-kit
./scripts/test.sh        # all suites, no credentials required
```

---

## What's here

```
modules/
  naming/                 cross-cloud naming + tag/label contract (no provider)
  aws-network/            VPC, per-AZ subnets, IGW, optional NAT
  aws-container-service/  ECS Fargate behind an ALB, with rollout circuit breaker
  aws-postgres/           RDS Postgres, encrypted, backed up, private
  aws-cache/              ElastiCache Redis with an explicit eviction policy
  aws-observability/      CloudWatch alarms + dashboard + SNS topic
  gcp-network/            custom VPC, private services peering, VPC connector
  gcp-service/            Cloud Run v2 with a least-privilege runtime identity
  gcp-postgres/           Cloud SQL Postgres, private IP only, password in Secret Manager
stacks/
  aws/                    the AWS composition, with a stack-level test suite
  gcp/                    the GCP composition, with a stack-level test suite
examples/
  local/                  a real `terraform apply` with no cloud account
scripts/
  test.sh                 run every suite
  validate.sh             fmt check + per-module validate
```

Two stacks, because the same service should be deployable either way and the
decision should be a stack choice rather than a rewrite.

---

## The testing approach

This is the part worth reading, because it is the reason the repo can be verified
by someone who does not trust me and does not have an AWS account.

Terraform 1.7 added `mock_provider`, which lets a test run the **real**
configuration — real variable validation, real preconditions, real expressions,
real resource graph — against a fake provider API. Nothing is provisioned and
nothing is authenticated, so the suite is fast, free, and safe to run on a fork's
pull request.

```bash
terraform test        # in any module or stack directory
```

What that buys, concretely — every one of these is a real assertion that runs on
every commit:

- **Private subnets cannot take a public IP**, and the private route table has no
  default route when NAT is disabled.
- **Task ingress is scoped to the load balancer's security group**, asserted
  across every rule, and no rule may name a CIDR block.
- **No secret is ever an environment variable** — every secret is a Secrets
  Manager ARN, and no secret name may appear in the plain environment map.
- **Postgres and Redis accept connections only from the service's task security
  group**, and never from the load balancer's.
- **The deployment circuit breaker is enabled *and* rolls back** — detection
  without rollback still leaves a broken revision live.
- **Every alarm sets `treat_missing_data` explicitly.** The CloudWatch default is
  `missing`, so an alarm on a service that has stopped reporting entirely never
  fires — the exact case you most want paged.
- **Cloud SQL has no public IPv4 address and requires TLS.**
- **Cloud Run grants no public invoker role** unless explicitly asked, and its
  runtime identity is a dedicated service account rather than the shared default.
- **The database password is generated and written straight to Secret Manager**,
  so it is never a Terraform variable and never appears in state.

### The stack-level suites matter more than the module ones

Each module suite proves one component. Both stacks carry an integration suite
that proves the **composition** — that the modules are wired to each other
correctly, which is where bugs actually live. A module can be perfect and the
stack still hand the application the wrong database host, or grant the load
balancer's security group to the database.

The stack suites read a module's **published composition surface** (outputs like
`container_environment`, `container_secrets`, `allowed_client_security_group_ids`)
rather than reaching into resources. That is deliberate: it makes the wiring
assertions readable, and it keeps the module's public contract honest.

### Four bugs these tests caught

Not hypothetical — each was found by running the suite while building this, and
each is a real defect that would have reached production:

1. **Wrong metric-dimension suffix.** The ARN-suffix derivation for the target
   group dropped the `targetgroup/` prefix, so the error-rate and latency alarms
   would have watched a dimension that never reports. An alarm that silently
   watches nothing is worse than no alarm, because you believe you are covered.
   The integration test asserts the shape of both suffixes and caught it on the
   first run.
2. **`count` on a computed value.** The secret-read IAM policy used
   `count = length(var.secrets) > 0 ? 1 : 0`, where `var.secrets` is derived from
   RDS's *computed* managed-secret ARN. A count that cannot be determined at plan
   time forces a two-phase apply and fails outright in a plan-only pipeline. Fixed
   by creating the policy unconditionally and scoping it via an empty `Resource`
   list — strictly narrower than a wildcard, and fully known at plan time.
3. **Implicit provider default on a security-relevant field.**
   `map_public_ip_on_launch` was left unset on private subnets, relying on the
   provider default. Correct today, and one provider upgrade away from being
   wrong. Now stated explicitly, because the whole point of that tier is that
   instances in it cannot hold a public address.
4. **Invalid Fargate task size reaching the provider.** `cpu = 512, memory = 8192`
   is rejected at apply with an opaque message. A precondition now names the legal
   pairings at plan time.

The lesson generalised: **the composition layer is where the bugs are, and
assertions about a system's security posture belong in the test suite, not in a
review checklist.** Each of the four above is a sentence someone would have
written in a PR description and nobody would have verified.

### Beyond plan: a real apply

`examples/local/` runs an actual `terraform apply` — real state file, real
resources, real outputs — using the `local` provider. No credentials, no cloud,
no cost. It exists so the repo contains at least one artifact demonstrating the
whole pipeline rather than only making claims about it:

```bash
cd examples/local && terraform init && terraform apply -auto-approve
```

---

## Design decisions worth stating

**One naming contract, two clouds.** `modules/naming` derives the resource name,
the AWS tag map and the GCP label map from the same inputs, and declares no
provider at all — which is why its 7 assertions run in milliseconds with no mock.
The two clouds have genuinely different metadata rules (GCP labels are lowercase
only, `[a-z0-9_-]`, max 63 chars, and a `.` is illegal), so deriving both from one
place is what stops them drifting apart. There is a test that asserts a hyphenated
project name normalises correctly for GCP and that no region value is smuggled
into the label set as an AWS tag would be.

**Credentials are references, never values.** Nowhere in this repo is a password
an input. RDS manages its own master credential in Secrets Manager; Cloud SQL
generates one and writes it to Secret Manager. The application receives an ARN or
a secret id, and the task/execution role is scoped to exactly those ARNs.

**Data tiers are private by construction, not by rule.** Postgres and Redis sit in
private subnets with security groups whose ingress names *other security groups*,
never CIDR blocks — so the rule survives a subnet renumber and cannot accidentally
expose a whole block. Cloud SQL's `ipv4_enabled` is `false`, so there is no public
address to reach.

**Rollouts protect themselves.** The ECS service runs the deployment circuit
breaker with `rollback = true`, and the test asserts both flags. A deploy that
never reaches a steady state reverts rather than leaving the service half-up.

**Fail loudly at plan time.** Every precondition exists because the provider's own
error for the same mistake is opaque: illegal Fargate task sizes, `multi_az`
missing in production, failover with no replica to promote, a connector CIDR
overlapping the subnet, a GCP instance that is zonal in production.

**Environments change cost, not correctness.** `dev` skips the database standby
and NAT egress; it never skips storage encryption or backups. Both are asserted,
in both directions, in the stack suite.

---

## Honest limits

- **Nothing here has been applied to a real AWS or GCP account.** The module and
  stack suites run against mocked providers, and the only real apply is the
  `local` example. The configuration is validated against the real provider
  *schemas* (every module passes `terraform validate` with the actual AWS 6.x and
  Google 6.x providers), but schema-valid is not the same as provisioned. Treat
  this as verified configuration, not as a deployed estate.
- **The AWS and GCP stacks are not equivalent in capability.** The AWS half covers
  network, compute, both data tiers and observability. The GCP half has no cache
  tier and no equivalent of the observability module — Cloud Monitoring alarms
  would be the next piece.
- **No remote state, no locking.** State backends are deliberately out of scope
  here; every real deployment needs one (S3 + DynamoDB, or a GCS bucket) and that
  is a decision per environment rather than a repo default.
- **No CI-side security scanner.** `terraform fmt` and `terraform validate` gate
  the pipeline. A policy tool (Checkov, tfsec or OPA) would be the natural next
  step and is not wired up.
- **The `dev` defaults are chosen for cost, not safety in a hostile sense.** There
  is no WAF, no TLS certificate on the ALB listener (it terminates plain HTTP),
  and no private networking between the two stacks. This is a service skeleton,
  not a hardened deployment.

---

## Running it

```bash
# everything: format check, per-module validate, all 11 test suites
./scripts/validate.sh && ./scripts/test.sh

# one component
cd modules/aws-container-service && terraform init && terraform test

# the real apply
cd examples/local && terraform init && terraform apply -auto-approve
```

Requires Terraform >= 1.7 (the `mock_provider` feature) and nothing else.

## License

MIT
