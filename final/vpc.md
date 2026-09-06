# vpc.md — Foundational Network (Deliverable B, documented)

Companion to the annotated `vpc.tf` — Deliverable B's scope exactly: **VPC,
subnets, route tables, IGW, NAT, and the TGW attachment only.** EKS/ECS is a
commented stub. No module tree is built; the decomposition below is a comment
block sketching how this would split in the real repo, per the exercise's own
instruction.

This file exists so the Terraform can be talked through without reading raw HCL —
useful for the "could a peer implement from this document?" bar, and for walking
an interviewer through the file live.

---

## Module decomposition (sketch, not built)

```
modules/
  network-core/      <- this file's content: VPC (+ secondary pod CIDR
                        association), subnets, route tables, IGW, NAT,
                        TGW attachment. One instance per region.
  network-endpoints/  <- interface/gateway VPC endpoints (ECR, S3, STS,
                        CloudWatch) — separate because it changes far
                        more often than the VPC shell.
  security-groups/    <- owned by the platform team (sg-nlb-public,
                        sg-eks-private), referenced by ARN/ID from
                        app-team modules, never created by them.
  compute-eks/         <- cluster + Karpenter module, called from
                        environments/, consumes subnet IDs and the pod
                        CIDR as outputs of network-core (see the
                        commented stub in vpc.tf).

environments/us-west-2-prod/main.tf wires these together and passes in the
CIDR blocks from the central IPAM allocation for this hub.
```

Comments explaining *why* count more than working HCL — that's the standard
applied throughout `vpc.tf` and repeated here.

---

## Variables — and the one fix that matters

`vpc.tf` declares `hub_cidr` (`10.100.0.0/16`), `pod_secondary_cidr`
(`100.64.0.0/16`), `ground_cidr` (`10.200.0.0/16`), and `org_cidrs`. The first
three are correct as written and match `NETWORK-DESIGN.md`'s CIDR strategy
exactly.

**`org_cidrs` needs a corrected default.** An earlier draft used
`10.96.0.0/11` as a placeholder — which, checked against the actual range
(`10.96.0.0/11` spans `10.96.0.0–10.127.255.255`), **overlaps `10.100.0.0/16`**,
the hub's own VPC CIDR. AWS's implicit local-route precedence means this
wouldn't have actually broken routing, but it directly contradicts the "avoids
collisions as Skylo adds hubs" claim the design makes elsewhere, and it's exactly
the kind of thing an interviewer checks by hand.

Corrected block, consistent with `NETWORK-DESIGN.md`'s three-address-family
scheme:

```hcl
variable "org_cidrs" {
  description = "Other Skylo AWS Organization account CIDRs, reachable east-west over the TGW's Org route table (never the Ground route table). Sourced from a different RFC1918 block than hub_cidr/ground_cidr on purpose — see NETWORK-DESIGN.md's CIDR strategy for why that structurally prevents collisions rather than just avoiding them by convention."
  type        = list(string)
  default     = ["172.16.0.0/12"]
}
```

Everything downstream that consumes `org_cidrs` (the `aws_route.private_to_org`
resource, keyed per-AZ-per-CIDR) is unaffected by this fix — it already treats
`org_cidrs` as an opaque list, so correcting the default is a one-line change.

---

## Resource walkthrough (matches `vpc.tf`, in order)

- **`aws_vpc.hub`** — the `10.100.0.0/16` hub VPC, DNS support/hostnames on.
- **`aws_vpc_ipv4_cidr_block_association.pods`** — the secondary
  `100.64.0.0/16` pod CIDR, associated at the VPC level so any subnet can draw
  from it via prefix delegation. Kept as its own resource because it's a
  logically distinct address plan: allocated differently, reused identically
  across hubs, never routed over the TGW.
- **`aws_internet_gateway.igw`** — one per VPC, attached once.
- **`aws_subnet.public` / `aws_subnet.private`** (`for_each` over the 3 AZs) —
  the tiers from `NETWORK-DESIGN.md`. Public subnets don't auto-assign public
  IPs; NAT and the NLB get explicit EIPs instead.
- **`aws_eip.nat` / `aws_nat_gateway.this`** (`for_each` over the 3 AZs) — one
  NAT Gateway per AZ, deliberately not shared. A shared NAT is a cost
  optimization that becomes a cross-AZ single point of failure — not acceptable
  against the "resilient to single-AZ failure" constraint.
- **`aws_ec2_transit_gateway_vpc_attachment.hub`** — one attachment, subnet IDs
  drawn from all three private subnets (one ENI per AZ, AWS's own guidance for
  attachment placement). Which CIDRs actually flow across it (ground vs. org,
  segmented) is controlled entirely by the TGW's own route tables — out of
  scope for this file, documented in `NETWORK-DESIGN.md`.
- **`aws_route_table.public`** — one shared table, `0.0.0.0/0 → IGW` only. No
  route to ground/org CIDRs from the public tier, on purpose.
- **`aws_route_table.private`** (`for_each` over the 3 AZs) — one table per AZ,
  never shared.
- **`aws_route.private_default_nat`** — default route to *that AZ's own* NAT
  Gateway.
- **`aws_route.private_to_ground`** — `ground_cidr` → the TGW attachment.
- **`aws_route.private_to_org`** — `org_cidrs` → the TGW attachment, flattened
  per AZ-per-CIDR so multiple org CIDRs can be added later without touching the
  resource shape.
- **`module "eks"` (commented stub)** — intentionally not built out. Scope for
  this deliverable is the network shell only; the stub records where
  `compute-eks` would attach (subnet IDs, pod CIDR, private-only control-plane
  endpoint) without spending time on it here.

---

## What's explicitly not in this file

No security-group resources (owned by the platform team, referenced by ID —
see the module decomposition above), no EKS/compute resources beyond the
commented stub, no VPC endpoint resources (ECR/S3/STS — a separate
`network-endpoints` module), and no DR/multi-region resources. All by design,
matching Deliverable B's stated scope.
