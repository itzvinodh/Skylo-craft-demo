############################################################################
# Skylo Regional Hub — Foundational Network (us-west-2)
#
# Scope of this file: VPC, subnets, route tables, IGW, NAT, and the TGW
# attachment only. Matches DESIGN.md/NETWORK-DESIGN.md A1 exactly:
# 10.100.0.0/16 hub VPC, 10.200.0.0/16 ground segment, public/private tiers
# x3 AZ. Per the exercise: EKS/ECS is a commented stub, no SG resources here
# (see DESIGN.md A5 for the IAM/security model — SGs live in a separate
# sg.tf owned by the platform/network team, not bundled into the network
# module, so app teams can never touch them).
#
# ---------------------------------------------------------------------
# MODULE DECOMPOSITION (how this would actually be split in the repo):
#
# modules/
#   network-core/      <- this file's content: VPC (+ secondary pod
#                         CIDR association), subnets, RTs, IGW, NAT,
#                         TGW attachment. One instance per region.
#   network-endpoints/ <- interface/gateway VPC endpoints (ECR, S3,
#                         STS, CloudWatch) — separate because it
#                         changes far more often than the VPC shell.
#   security-groups/   <- owned by platform team (sg-nlb-public,
#                         sg-eks-private), referenced by ARN/ID from
#                         app-team modules, never created by them.
#   compute-eks/        <- cluster + Karpenter + ENIConfig module,
#                         called from environments/, consumes subnet
#                         IDs and the pod CIDR as outputs of
#                         network-core (see stub below).
#
# environments/us-west-2-prod/main.tf would wire these together and pass
# in the CIDR blocks from the central IPAM allocation for this hub.
# ---------------------------------------------------------------------

terraform {
  required_providers {
    aws = { source = "hashicorp/aws", version = "~> 5.0" }
  }
}

variable "region" {
  default = "us-west-2"
}

variable "hub_cidr" {
  # Allocated from the central IPAM supernet reserved for hub VPCs
  # (10.0.0.0/9 — see NETWORK-DESIGN.md's CIDR strategy), NOT chosen ad
  # hoc. Hub #1 in that supernet; hub #2 would get 10.101.0.0/16, etc.
  # Hardcoding the literal here only because the take-home says the TGW
  # itself can be a variable; in the real repo this comes from the IPAM
  # pool data source.
  default = "10.100.0.0/16"
}

variable "pod_secondary_cidr" {
  # Secondary VPC CIDR for EKS pod IPs (VPC CNI custom networking + prefix
  # delegation), carved from the RFC 6598 shared space (100.64.0.0/10) —
  # see NETWORK-DESIGN.md A1. Deliberately NOT sized/allocated by the same
  # IPAM discipline as hub_cidr: pod IPs never cross the TGW, so every
  # regional hub can reuse this exact /16 with zero collision risk.
  default = "100.64.0.0/16"
}

variable "azs" {
  default = ["us-west-2a", "us-west-2b", "us-west-2c"]
}

# The TGW is provisioned once per region by the network-core account and
# shared into this account via RAM. Treating it as a variable rather than
# a resource here — this VPC only attaches to it.
variable "transit_gateway_id" {
  description = "TGW ID, RAM-shared from the network account"
  type        = string
}

# Ground network (on-prem/ground-station side), reachable over the TGW via
# Direct Connect (see NETWORK-DESIGN.md A1/A4). Allocated from its own
# reserved supernet (10.128.0.0/9 — the other half of the same /8 hub_cidr
# is drawn from), so ground space and hub-VPC space can never collide as
# more hubs are added.
variable "ground_cidr" {
  type    = string
  default = "10.200.0.0/16"
}

# Other Skylo Org account CIDRs, reachable east-west over the *same* TGW
# attachment but — per NETWORK-DESIGN.md A1 — via a second, separately-owned
# TGW route table, so ground traffic and Org traffic stay segmented at the
# TGW rather than flattened into one routing domain. This variable only
# controls what this VPC's route table forwards toward the TGW; the actual
# segmentation enforcement is the TGW route table, out of scope for this
# file.
#
# Sourced from 172.16.0.0/12 — a different RFC1918 block entirely, not a
# sub-range of the 10.0.0.0/8 space hub_cidr/ground_cidr are drawn from —
# so no amount of hub growth can ever collide with org space. See vpc.md
# for the full CIDR-strategy writeup.
variable "org_cidrs" {
  type    = list(string)
  default = ["172.16.0.0/12"]
}

locals {
  # Single index map reused by every per-AZ resource below so subnets,
  # route tables, NAT gateways, and EIPs all key off the same AZ string —
  # avoids drift between resources that must line up 1:1 per AZ.
  az_index = { for i, az in var.azs : az => i }
}

# ---------------------------------------------------------------------
# VPC
# ---------------------------------------------------------------------
resource "aws_vpc" "hub" {
  cidr_block           = var.hub_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true
  tags = {
    Name = "skylo-hub-us-west-2"
    # Tag with the IPAM pool ID in the real repo so the allocation is
    # traceable from the resource itself, not just documentation.
  }
}

# Secondary CIDR for pod IPs — associated at the VPC level so subnets in
# the private tier (or a dedicated pod-subnet, in a fuller build) can draw
# from it via prefix delegation. Kept as its own resource because it's
# logically a distinct address plan from hub_cidr: allocated differently,
# reused identically across hubs, never routed over the TGW.
resource "aws_vpc_ipv4_cidr_block_association" "pods" {
  vpc_id     = aws_vpc.hub.id
  cidr_block = var.pod_secondary_cidr
}

resource "aws_internet_gateway" "igw" {
  vpc_id = aws_vpc.hub.id
  tags   = { Name = "skylo-hub-igw" }
}

# ---------------------------------------------------------------------
# SUBNETS — 2 tiers x 3 AZs, matching NetworkDesign.png exactly. No
# separate tgw-attach tier: the TGW attachment ENIs land in the private
# subnets (see NETWORK-DESIGN.md A1 for the trade-off — a dedicated tier
# gives cleaner blast-radius separation, added later if a security review
# asks).
# ---------------------------------------------------------------------
resource "aws_subnet" "public" {
  for_each                = local.az_index
  vpc_id                  = aws_vpc.hub.id
  availability_zone       = each.key
  cidr_block              = cidrsubnet(var.hub_cidr, 8, each.value) # 10.100.0.0/24, .1.0/24, .2.0/24
  map_public_ip_on_launch = false                                    # NAT/NLB get explicit EIPs, no auto-assign
  tags                    = { Name = "skylo-public-${each.key}", Tier = "public" }
}

resource "aws_subnet" "private" {
  for_each                = local.az_index
  vpc_id                  = aws_vpc.hub.id
  availability_zone       = each.key
  cidr_block              = cidrsubnet(var.hub_cidr, 8, (each.value + 1) * 10) # 10.100.10.0/24, .20.0/24, .30.0/24
  map_public_ip_on_launch = false
  # /24 deliberately: Karpenter's own stated ceiling is 100 nodes/AZ (see
  # NETWORK-DESIGN.md A1) — 251 usable IPs covers that with headroom for
  # the TGW attachment ENI and interface-endpoint ENIs. Subnets don't
  # resize in place, so this is sized for the target, not the day-1 node
  # count.
  tags = { Name = "skylo-private-${each.key}", Tier = "private" }
}

# ---------------------------------------------------------------------
# NAT — one per AZ, deliberately not one shared NAT. A shared NAT is a
# cost optimization that turns into a cross-AZ single point of failure;
# not worth it for a network this exercise's constraints call "resilient
# to single-AZ failure."
# ---------------------------------------------------------------------
resource "aws_eip" "nat" {
  for_each = local.az_index
  domain   = "vpc"
  tags     = { Name = "skylo-nat-eip-${each.key}" }
}

resource "aws_nat_gateway" "this" {
  for_each      = local.az_index
  subnet_id     = aws_subnet.public[each.key].id
  allocation_id = aws_eip.nat[each.key].id
  tags          = { Name = "skylo-nat-${each.key}" }
}

# ---------------------------------------------------------------------
# TGW ATTACHMENT — one subnet per AZ (private tier), per AWS's own
# guidance for attachment ENI placement.
# ---------------------------------------------------------------------
resource "aws_ec2_transit_gateway_vpc_attachment" "hub" {
  transit_gateway_id = var.transit_gateway_id
  vpc_id             = aws_vpc.hub.id
  subnet_ids         = [for s in aws_subnet.private : s.id]
  tags               = { Name = "skylo-hub-tgw-attach" }

  # NOTE: which CIDRs actually flow across this attachment, and whether
  # ground traffic can reach Org accounts (it shouldn't, by default), is
  # controlled by the TGW's own route tables (split ground vs.
  # org-east-west — see NETWORK-DESIGN.md A1), not by anything in this
  # VPC. That segmentation lives in the network-core account's TGW
  # config, out of scope for this file.
}

# ---------------------------------------------------------------------
# ROUTE TABLES — one shared table for public (identical routing in every
# AZ), one table per AZ for private (own-AZ NAT only, no cross-AZ NAT
# dependency).
# ---------------------------------------------------------------------
resource "aws_route_table" "public" {
  vpc_id = aws_vpc.hub.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.igw.id
  }
  tags = { Name = "skylo-rt-public" }
  # Deliberately NOT routing ground_cidr/org_cidrs here — the public tier
  # (NAT + customer NLB) has no business reaching ground/org CIDRs
  # directly; that's an intentional blast-radius boundary, not an
  # oversight.
}

resource "aws_route_table_association" "public" {
  for_each       = aws_subnet.public
  subnet_id      = each.value.id
  route_table_id = aws_route_table.public.id
}

resource "aws_route_table" "private" {
  for_each = local.az_index
  vpc_id   = aws_vpc.hub.id
  tags     = { Name = "skylo-rt-private-${each.key}" }
}

resource "aws_route" "private_default_nat" {
  for_each               = aws_route_table.private
  route_table_id         = each.value.id
  destination_cidr_block = "0.0.0.0/0"
  nat_gateway_id         = aws_nat_gateway.this[each.key].id
}

resource "aws_route" "private_to_ground" {
  for_each               = aws_route_table.private
  route_table_id         = each.value.id
  destination_cidr_block = var.ground_cidr
  transit_gateway_id     = var.transit_gateway_id
  depends_on             = [aws_ec2_transit_gateway_vpc_attachment.hub]
}

resource "aws_route" "private_to_org" {
  for_each = { for pair in flatten([
    for rt_key, rt in aws_route_table.private : [
      for cidr in var.org_cidrs : { key = "${rt_key}-${cidr}", rt = rt.id, cidr = cidr }
    ]
  ]) : pair.key => pair }
  route_table_id         = each.value.rt
  destination_cidr_block = each.value.cidr
  transit_gateway_id     = var.transit_gateway_id
  depends_on             = [aws_ec2_transit_gateway_vpc_attachment.hub]
}

# A Gateway Endpoint route for S3 (destination = the S3 prefix list,
# target = the endpoint) would also live in these private route tables —
# see NetworkDesign.png. Omitted as a resource here on purpose: it's
# owned by the network-endpoints module (see decomposition block above),
# not the VPC shell this file scopes to.

resource "aws_route_table_association" "private" {
  for_each       = aws_subnet.private
  subnet_id      = each.value.id
  route_table_id = aws_route_table.private[each.key].id
}

# ---------------------------------------------------------------------
# COMPUTE — out of scope per the exercise instructions. Stub only.
# ---------------------------------------------------------------------
# module "eks" {
#   source             = "../compute-eks"
#   vpc_id             = aws_vpc.hub.id
#   subnet_ids         = [for s in aws_subnet.private : s.id]
#   pod_secondary_cidr = aws_vpc_ipv4_cidr_block_association.pods.cidr_block
#   # cluster_endpoint_public_access = false — control plane private-only,
#   # consistent with everything else in this hub. See DESIGN.md A2 for
#   # the EKS-vs-ECS decision, A1 for the pod-CIDR/prefix-delegation
#   # wiring, and A5 for the IRSA/IAM model this module would set up per
#   # workload (Karpenter provisioner IAM, node IAM, no wildcard actions).
# }
