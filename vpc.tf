############################################################################
# Skylo Regional Hub — Foundational Network (us-west-2)
#
# Scope of this file: VPC, subnets, route tables, IGW, NAT, and the TGW
# attachment only. Per the exercise: EKS/ECS is a commented stub, no SG
# resources here (see DESIGN.md A5 for the IAM/security model — SGs would
# live in a separate sg.tf owned by the platform/network team, not bundled
# into the network module, so app teams can never touch them).
#
# ---------------------------------------------------------------------
# MODULE DECOMPOSITION (how this would actually be split in the repo):
#
#   modules/
#     network-core/        <- this file's content: VPC, subnets, RTs, IGW,
#                              NAT, TGW attachment. One instance per region.
#     network-endpoints/    <- interface/gateway VPC endpoints (ECR, S3,
#                              STS, CloudWatch) — separate because it
#                              changes far more often than the VPC shell.
#     security-groups/      <- owned by platform team, referenced by ARN/ID
#                              from app-team modules, never created by them.
#     compute-eks/           <- cluster module, called from environments/,
#                              consumes subnet IDs as outputs of
#                              network-core (see stub below).
#
#   environments/us-west-2-prod/main.tf would wire these together and pass
#   in the CIDR block from the central IPAM allocation for this hub.
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
  # Allocated from the central IPAM supernet for this continent, NOT chosen
  # ad hoc — see DESIGN.md A1 CIDR strategy. Hardcoding the literal here
  # only because the take-home says the TGW itself can be a variable; in
  # the real repo this comes from the IPAM pool data source.
  default = "10.30.0.0/16"
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

# CIDRs this hub needs reachable via the TGW (ground stations + other Org
# accounts). Kept as a variable, not hardcoded, because the TGW route
# table — not this list — is the actual access-control boundary; this is
# just what the VPC route table forwards toward the TGW.
variable "tgw_routable_cidrs" {
  type    = list(string)
  default = ["10.0.0.0/8"] # placeholder: ground + org supernet
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

resource "aws_internet_gateway" "igw" {
  vpc_id = aws_vpc.hub.id
  tags   = { Name = "skylo-hub-igw" }
}

# ---------------------------------------------------------------------
# SUBNETS — 4 tiers x 3 AZs. See DESIGN.md A1 for the full table; the
# short version: tgw-attach and private-app/private-data never see a
# public IP, only public-edge does.
# ---------------------------------------------------------------------
resource "aws_subnet" "tgw_attach" {
  for_each                = { for i, az in var.azs : az => i }
  vpc_id                  = aws_vpc.hub.id
  availability_zone       = each.key
  cidr_block              = cidrsubnet(var.hub_cidr, 8, each.value)        # 10.30.0.0/24 etc
  map_public_ip_on_launch = false
  tags                    = { Name = "skylo-tgw-attach-${each.key}", Tier = "tgw-attach" }
}

resource "aws_subnet" "private_app" {
  for_each                = { for i, az in var.azs : az => i }
  vpc_id                  = aws_vpc.hub.id
  availability_zone       = each.key
  cidr_block              = cidrsubnet(var.hub_cidr, 4, 1 + each.value)    # 10.30.16.0/20 etc — EKS nodes / UPF pods
  map_public_ip_on_launch = false
  tags                    = { Name = "skylo-private-app-${each.key}", Tier = "private-app" }
}

resource "aws_subnet" "private_data" {
  for_each                = { for i, az in var.azs : az => i }
  vpc_id                  = aws_vpc.hub.id
  availability_zone       = each.key
  cidr_block              = cidrsubnet(var.hub_cidr, 4, 4 + each.value)    # 10.30.32.0/20 etc — ElastiCache, VPC endpoints
  map_public_ip_on_launch = false
  tags                    = { Name = "skylo-private-data-${each.key}", Tier = "private-data" }
}

resource "aws_subnet" "public_edge" {
  for_each                = { for i, az in var.azs : az => i }
  vpc_id                  = aws_vpc.hub.id
  availability_zone       = each.key
  cidr_block              = cidrsubnet(var.hub_cidr, 8, 48 + each.value)   # 10.30.48.0/24 etc — NAT GW + customer NLB only
  map_public_ip_on_launch = false                                          # NLB/NAT get their own EIPs; no auto-assign
  tags                    = { Name = "skylo-public-edge-${each.key}", Tier = "public-edge" }
}

# ---------------------------------------------------------------------
# NAT — one per AZ, deliberately not one shared NAT. A shared NAT is a
# cost optimization that turns into a cross-AZ single point of failure;
# not worth it for a network this exercise's constraints call "resilient
# to single-AZ failure."
# ---------------------------------------------------------------------
resource "aws_eip" "nat" {
  for_each = aws_subnet.public_edge
  domain   = "vpc"
  tags     = { Name = "skylo-nat-eip-${each.key}" }
}

resource "aws_nat_gateway" "this" {
  for_each      = aws_subnet.public_edge
  subnet_id     = each.value.id
  allocation_id = aws_eip.nat[each.key].id
  tags          = { Name = "skylo-nat-${each.key}" }
}

# ---------------------------------------------------------------------
# TGW ATTACHMENT — one subnet per AZ, per AWS's own guidance (one subnet
# per AZ is required/recommended for the attachment ENIs).
# ---------------------------------------------------------------------
resource "aws_ec2_transit_gateway_vpc_attachment" "hub" {
  transit_gateway_id = var.transit_gateway_id
  vpc_id              = aws_vpc.hub.id
  subnet_ids          = [for s in aws_subnet.tgw_attach : s.id]
  tags                = { Name = "skylo-hub-tgw-attach" }

  # NOTE: which CIDRs actually flow across this attachment is controlled
  # by the TGW's own route tables (split ground vs org-east-west — see
  # DESIGN.md), not by anything in this VPC. That segmentation lives in
  # the network-core account's TGW config, out of scope for this file.
}

# ---------------------------------------------------------------------
# ROUTE TABLES — one per tier per AZ for the private tiers (own-AZ NAT
# only, no cross-AZ NAT dependency), one shared table for public-edge.
# ---------------------------------------------------------------------
resource "aws_route_table" "private_app" {
  for_each = aws_subnet.private_app
  vpc_id   = aws_vpc.hub.id
  tags     = { Name = "skylo-rt-private-app-${each.key}" }
}

resource "aws_route" "private_app_default" {
  for_each               = aws_route_table.private_app
  route_table_id         = each.value.id
  destination_cidr_block = "0.0.0.0/0"
  nat_gateway_id          = aws_nat_gateway.this[each.key].id
}

resource "aws_route" "private_app_tgw" {
  for_each               = { for pair in flatten([
                              for rt_key, rt in aws_route_table.private_app : [
                                for cidr in var.tgw_routable_cidrs : { key = "${rt_key}-${cidr}", rt = rt.id, cidr = cidr }
                              ]
                            ]) : pair.key => pair }
  route_table_id          = each.value.rt
  destination_cidr_block  = each.value.cidr
  transit_gateway_id      = var.transit_gateway_id
  depends_on              = [aws_ec2_transit_gateway_vpc_attachment.hub]
}

resource "aws_route_table_association" "private_app" {
  for_each       = aws_subnet.private_app
  subnet_id      = each.value.id
  route_table_id = aws_route_table.private_app[each.key].id
}

# private_data and tgw_attach route tables follow the same pattern as
# private_app (own-AZ NAT for egress, TGW route for ground/org CIDRs).
# Omitted here — identical HCL repeated 2x — to keep this file readable;
# in the real module this is a single `for_each` over a tier map instead
# of three near-duplicate resource blocks. Flagging the duplication
# rather than hiding it.

resource "aws_route_table" "public_edge" {
  vpc_id = aws_vpc.hub.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.igw.id
  }
  tags = { Name = "skylo-rt-public-edge" }
  # Deliberately NOT routing tgw_routable_cidrs here — the public tier
  # (NAT + customer NLB) has no business reaching ground/org CIDRs
  # directly; that's an intentional blast-radius boundary, not an
  # oversight.
}

resource "aws_route_table_association" "public_edge" {
  for_each       = aws_subnet.public_edge
  subnet_id      = each.value.id
  route_table_id = aws_route_table.public_edge.id
}

# ---------------------------------------------------------------------
# COMPUTE — out of scope per the exercise instructions. Stub only.
# ---------------------------------------------------------------------
# module "eks" {
#   source     = "../compute-eks"
#   vpc_id     = aws_vpc.hub.id
#   subnet_ids = [for s in aws_subnet.private_app : s.id]
#   # cluster_endpoint_public_access = false — control plane private-only,
#   # consistent with everything else in this hub. See DESIGN.md A2 for
#   # the EKS-vs-ECS decision and A5 for the IRSA/IAM model this module
#   # would wire up per workload.
# }
