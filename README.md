# Skylo — Staff Cloud Engineer — Interview Prep

## Contents

- **`Interview-Cheat-Sheet.pdf`** — one page. The thing to actually reread right before you
  walk in. Take-home Q&A in compressed form, the questions you already worked through with
  Meta AI (corrected), and the curveballs the take-home itself warns they'll throw at you
  ("pushing on your trade-offs and changing a requirement to see how the architecture bends").
- **`DESIGN.md`** — the full write-up matching the take-home's actual sections (A1–A5), rebuilt
  to be defensible under follow-up questioning: real trade-offs, no invented numbers.
- **`vpc.tf`** — a single annotated Terraform file matching Deliverable B's exact scope
  (VPC/subnets/route tables/IGW/NAT/TGW attachment only, EKS as a commented stub, a module
  decomposition comment block instead of an actual module tree — that's what the spec asks
  for).
- **`reference/`** — the SG/NLB and GitOps/ArgoCD material from your Meta AI conversation,
  corrected and kept separate because it's *not* part of the graded deliverable, but useful if
  the interviewer pushes into "how would you deploy and expose this."

## Two things worth knowing before the interview

1. **Only `argocd.tf` ever actually reached your Skylo folder.** Meta AI said it packaged
   `vpc.tf`, `eks.tf`, `sg.tf`, `nlb.tf`, `README.md`, and a `skylo-final.zip` with diagrams —
   none of that existed on disk. If you'd walked in assuming that full package was ready, it
   wasn't. This folder replaces the gap with real files that match what was actually asked for.
2. **Some numbers in the original conversation were invented, not measured** — specific
   millisecond latencies and dollar figures for PrivateLink/Gateway endpoints. The mechanism
   behind those claims is real and worth saying; the specific figures aren't something you
   benchmarked, so don't defend them as if they are. `reference/README.md` has the detail.
