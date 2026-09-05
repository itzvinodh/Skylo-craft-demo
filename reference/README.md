# Reference / backup material — NOT the take-home submission

These two files are **not** part of the graded deliverables. The take-home asks for exactly
`DESIGN.md` and one `vpc.tf` (see `../DESIGN.md` and `../vpc.tf`) — extra Terraform files would
actually work against you against the "IaC instinct / structure, naming, boundaries" signal the
rubric names, since the spec explicitly says "do not build a module tree" and to skip
EKS-adjacent resources entirely.

What's here instead: the security-group/load-balancer pattern and the GitOps/ArgoCD sketch you
worked out with Meta AI, cleaned up so they're accurate if the interviewer pushes past the
take-home into "okay, now how would you actually deploy to this and expose it" — which the
take-home's own follow-up section says they will do ("pushing on your trade-offs and changing a
requirement to see how the architecture bends").

**Two corrections from the original Meta AI conversation, worth knowing before you're asked:**

1. **The specific latency numbers ("5ms via Interface endpoint," "2ms via Gateway endpoint")
   and dollar figures ("$800/mo," "$720/mo," "75% saved," "$10.5k/mo") were never real AWS
   figures — they were generated, not measured or documented.** The *directional* claims are
   correct and worth making (Gateway endpoints route via the route table with no extra network
   hop; Interface/PrivateLink endpoints do add a hop and an hourly+per-GB charge; avoiding NAT
   egress for image pulls is a legitimate cost lever) — but if an interviewer asks "where does
   that number come from," the honest answer is "that was illustrative, not a benchmark I ran."
   Say the mechanism, not the invented number.
2. **The "skylo-final.zip" and the other 5 files (`vpc.tf`, `eks.tf`, `sg.tf`, `nlb.tf`,
   `README.md`) that Meta AI said it saved to `/mnt/data/` were never actually written to your
   Skylo folder** — only `argocd.tf` made it to disk. This rebuild (this whole `craft-demo/`
   folder) replaces that gap with real files.

## sg-nlb-pattern.tf

The one genuinely good catch in that conversation: **you correctly spotted that a security
group denying `0.0.0.0/0` on EKS has no way to let real customer traffic in**, and the fix
(public NLB is the only internet entry point; EKS's SG allows only the NLB's SG ID, never a
CIDR) is the standard, correct AWS pattern for this. It's cleaned up here as a talking point,
not wired into `vpc.tf` because SG/LB resources are out of scope for Deliverable B.

## gitops-argocd.tf

ArgoCD-based GitOps sketch (Git push → ArgoCD in-cluster → pulls from ECR → progressive
rollout). Legitimate pattern, kept as a "how I'd actually operate this day 2" talking point for
A2/A5 follow-ups, with the fabricated numbers stripped out.
