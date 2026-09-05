# Skylo — Staff Cloud Engineer — Interview Prep

## Contents

- **`NetworkDesign.jpeg`** / **`SkyloDesignArchitecture.jpeg`** — your own architecture diagrams,
  copied in here so `DESIGN.md`'s links resolve inside the zip. `NetworkDesign.jpeg` is treated as
  authoritative for the network layer (it's the more complete, versioned iteration); the other is
  the compute/registry-cache companion view.
- **`DESIGN.md`** — the full write-up matching the take-home's actual sections (A1–A5), rebuilt
  around the CIDR scheme and topology in your own diagrams (`10.100.0.0/16` hub VPC,
  `10.200.0.0/16` ground segment, Karpenter/HPA, dual-DX + VPN backup) instead of an invented one.
  Flags one deliberate departure from the diagram: public GTP-U (2152) is off by default — see
  A5.
- **`vpc.tf`** — a single annotated Terraform file matching Deliverable B's exact scope
  (VPC/subnets/route tables/IGW/NAT/TGW attachment only, EKS as a commented stub, a module
  decomposition comment block instead of an actual module tree — that's what the spec asks for),
  using the same CIDRs/tiers as `DESIGN.md` so the two deliverables don't contradict each other.
- **`reference/`** — the SG/NLB and GitOps/ArgoCD material from your Meta AI conversation,
  corrected and kept separate because it's *not* part of the graded deliverable, but useful if
  the interviewer pushes into "how would you deploy and expose this." Updated to the same CIDRs
  and the GTP-U-off-by-default call.

**Not yet updated:** `../Interview-Cheat-Sheet.pdf` still reflects the earlier `10.30.0.0/16`,
4-tier version of this design — it's now stale against `DESIGN.md`/`vpc.tf` above and needs a
regenerate pass before it's trustworthy to review from.

## Two things worth knowing before the interview

1. **Only `argocd.tf` ever actually reached your Skylo folder.** Meta AI said it packaged
   `vpc.tf`, `eks.tf`, `sg.tf`, `nlb.tf`, `README.md`, and a `skylo-final.zip` with diagrams —
   none of that existed on disk. If you'd walked in assuming that full package was ready, it
   wasn't. This folder replaces the gap with real files that match what was actually asked for.
2. **Some numbers in the original conversation were invented, not measured** — specific
   millisecond latencies and dollar figures for PrivateLink/Gateway endpoints. The mechanism
   behind those claims is real and worth saying; the specific figures aren't something you
   benchmarked, so don't defend them as if they are. `reference/README.md` has the detail.
