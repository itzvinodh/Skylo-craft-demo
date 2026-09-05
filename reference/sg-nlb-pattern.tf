############################################################################
# Reference only — see reference/README.md. Not part of the graded
# deliverable. This is the corrected version of the SG/NLB exchange from
# the Meta AI chat: the fix itself (NLB public, EKS reachable only from
# the NLB's SG, never from 0.0.0.0/0) is a legitimate, standard pattern —
# this file just writes it as clean, consistent HCL with the fabricated
# numbers removed.
############################################################################

# PUBLIC — the only internet-facing resource in the whole hub.
resource "aws_security_group" "nlb_public" {
  name        = "sg-nlb-public"
  vpc_id      = aws_vpc.hub.id
  description = "Public - NLB - sole internet entry point for the customer-facing path"

  ingress {
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
    description = "Customer dashboard/API — the one deliberate public surface"
  }
  # 2152/UDP (GTP-U) deliberately NOT opened here. Ground-station GTP-U
  # rides DX -> TGW -> private tier instead (see DESIGN.md A1/A5) — raw
  # GTP-U on the open internet is a known telco anti-pattern. Only add
  # this rule for a genuine non-DX device path (e.g. a roaming/interconnect
  # partner), and even then prefer fronting it with IPsec rather than a
  # bare UDP listener.
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["10.100.0.0/16"] # scoped to the hub VPC only, not 0.0.0.0/0
  }
  tags = { Zone = "public" }
}

# PRIVATE — EKS nodes. No 0.0.0.0/0 anywhere in this SG. That's the point.
resource "aws_security_group" "eks_private" {
  name        = "sg-eks-private"
  vpc_id      = aws_vpc.hub.id
  description = "Private - EKS worker nodes - reachable only from the NLB's SG, TGW CIDRs, and VPC endpoints"

  ingress {
    from_port       = 443
    to_port         = 443
    protocol        = "tcp"
    security_groups = [aws_security_group.nlb_public.id]
    description     = "From the public NLB only, by SG reference not CIDR"
  }
  # No 2152/UDP rule from the NLB's SG: the NLB doesn't listen on GTP-U by
  # default (see nlb_public above), so there's nothing to allow from it.
  # If a non-DX device path ever needs public GTP-U, add it in both places
  # together — never open it on eks_private alone.
  ingress {
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = concat([var.ground_cidr], var.org_cidrs)
    description = "Ground/Org traffic via TGW — private path, bypasses the NLB entirely"
  }
  tags = { Zone = "private" }
}

resource "aws_lb" "customer_nlb" {
  name               = "skylo-hub-nlb"
  internal           = false
  load_balancer_type = "network" # NLB, not ALB — keeps the option to carry UDP (GTP-U) later without swapping LB type; ALB is TCP/HTTP-only
  subnets            = [for s in aws_subnet.public : s.id]
  security_groups    = [aws_security_group.nlb_public.id]
}

resource "aws_lb_target_group" "customer_api" {
  name        = "skylo-customer-api"
  port        = 443
  protocol    = "TCP"
  vpc_id      = aws_vpc.hub.id
  target_type = "ip" # targets EKS pod IPs directly
}

# Why NLB and not ALB for this path, in one line: today's only public
# listener is 443, so ALB would work too — I'm picking NLB anyway because
# it preserves source IP and handles millions of concurrent flows more
# cheaply at this scale, and it leaves room to carry UDP (GTP-U) later
# without swapping load balancer type. If that headroom turns out not to
# matter, ALB is a perfectly reasonable alternative — say that trade-off
# out loud if asked "why not ALB."
