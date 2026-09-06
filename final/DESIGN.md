# Skylo Regional Hub — AWS Architecture Design (us-west-2)

## 0. Context and assumptions

Skylo runs a global Non-Terrestrial Network — smartphones and IoT devices connect
directly over satellites, served by cloud-native 3GPP vRAN and core. This hub in
**us-west-2** handles the two functions named in the brief:

1. **Data ingress** — high-volume, real-time connectivity data from multiple
   satellite ground stations, arriving over AWS Direct Connect.
2. **Core network processing** — containerized 3GPP core components managing
   device sessions, processing data, routing traffic.

Constraints treated as hard requirements: resilient to single-AZ failure; compute
scales with traffic; least-privilege and zero-trust; SOC 2 in scope; everything
provisioned as IaC; must connect to Direct Connect and to other accounts in the
Skylo AWS Organization. 3 AZs. Designing for "scales cleanly," not a specific
device count, since none was given beyond what Karpenter/HPA can already absorb.

**Network topology, CIDR strategy, and the worked data-flow/service-time example
live in [`NETWORK-DESIGN.md`](./NETWORK-DESIGN.md) — this document covers compute,
storage, and security/observability.**

**Scope note:** this artifact intentionally does not include a region-loss
DR section (RTO/RPO target and its cost). Single-AZ resilience — a named
constraint — is already built into the network and compute design below (per-AZ
NAT, per-AZ route tables, multi-AZ node/pod spread); it is not "DR," it's the
baseline. Region-level failover is a real follow-up question and I have a verbal
answer ready for it, but it's kept out of the written artifact by design so the
document stays focused on what's asked here.

---

## A2. Compute

**Decision: EKS**, with Karpenter for node autoscaling and HPA for pod
autoscaling — sized against traffic, not a fixed device count.

- The core-network pods need low-level networking access — custom CNI
  configuration, multiple NICs, and (for some components) host networking — to
  hit the throughput and latency profile 3GPP core workloads expect. EKS lets me
  run a custom CNI and the supporting device plugins as DaemonSets; ECS's
  networking model doesn't expose that layer on either launch type (Fargate or
  EC2).
- **Karpenter specifically, not cluster-autoscaler:** it provisions against the
  actual pending-pod resource shape instead of a fixed ASG shape. That matters
  here because data-ingress nodes and core-network-processing nodes want
  different instance types (network-optimized vs. general compute), and a fixed
  ASG per type is exactly the rigidity Karpenter removes.
- Telco-core vendor software ships as Helm charts and Operators with CRDs, not ECS
  task definitions — fighting the ecosystem's own packaging format is its own
  ongoing tax.
- Portability: if the same core stack needs to run at the edge or a second cloud
  later, Kubernetes travels; ECS task definitions don't.

**Cost, stated honestly:** EKS is a heavier operational surface — control-plane
version upgrades, add-on management (CoreDNS, VPC CNI + prefix-delegation config,
Karpenter, cert-manager), a real on-call skill requirement that ECS mostly hides.
Accepting that because the workload's networking needs make it non-negotiable,
not because Kubernetes is fashionable.

**The one thing that would reverse this decision:** if this hub's actual scope
turned out to be *only* the stateless control-plane/session-management services —
no low-level networking requirement, nothing that needs host networking or a
custom CNI — I'd run that slice on ECS/Fargate and drop the operational overhead
substantially. The reversing question is specifically: *does this hub run the
packet-processing workload, or only session/control logic?*

---

## A3. Storage

| Need | Service | Why |
|---|---|---|
| Short-term session state (high throughput, low latency) | **ElastiCache (Redis/Valkey), multi-AZ** | In-memory reads for session lookups, native TTL for session expiry, multi-AZ replication gives failover without a manual app-level failover path. |
| Long-term archival of connection logs | **S3, Standard → Intelligent-Tiering/Glacier lifecycle** | Durable and cheap at connection-log volume; queryable directly (Athena/Glue) for SOC 2 evidence pulls without standing up a second product. |

One honest nuance worth stating rather than skating past: ElastiCache in
cluster-mode gives multi-AZ failover at the *infrastructure* level automatically,
but a cluster-mode-enabled client still needs to be cluster-aware (handle
`MOVED`/`ASK` redirects) to benefit from it — "failover with no app-level
handling" is only fully true with a cluster-mode-disabled configuration behind a
client-side proxy. Worth confirming which posture the session-state client
library actually supports before calling this settled.

---

## A5. Security and observability

**IAM role model:** IRSA (or EKS Pod Identity) — every workload gets its own role
scoped to exactly what it calls, never the node's instance role. Deliberately
withheld from workload roles:

- Any wildcard (`*`) action or resource.
- `iam:PassRole` / `iam:CreateRole` — workloads never mint or hand off identity.
- Rights to modify security groups, route tables, or TGW attachments — network
  stays platform-owned; a compromised pod can't widen its own network access.
- Cross-account `sts:AssumeRole` beyond the one or two roles a service actually
  needs.

**The SG model, tied to the network diagram:** `sg-nlb-public` is the *only*
internet-facing security group in the hub. `sg-eks-private` (EKS nodes) allows
inbound only from `sg-nlb-public`'s own ID and the ground/org CIDRs via the TGW —
never a `0.0.0.0/0` rule anywhere on EKS itself. This is the standard AWS pattern
for "deny `0.0.0.0/0` on the compute tier without also blocking real customer
traffic": the NLB is the only thing that accepts the open internet, and
everything behind it trusts the NLB's security group, not an IP range.

**First 3 AWS security services, in order:**

1. **AWS Config** — the evidence engine: continuous resource recording plus
   managed rules is most of what a SOC 2 auditor asks to see, and it catches IaC
   drift from the baseline.
2. **GuardDuty** — VPC Flow Logs / DNS / CloudTrail / EKS audit-log threat
   detection with near-zero setup cost; the "did something bad actually happen"
   signal Config doesn't give.
3. **Security Hub** — aggregates Config + GuardDuty (+ Inspector once workloads
   run) into one CIS/AWS-FSBP-mapped view, instead of three consoles nobody
   checks.

**Top 3 metrics to alert on, for the containerized workloads:**

1. **Pod crash-loop / OOMKilled rate** — the earliest signal something is
   actually broken, not just slow.
2. **P99 session-processing latency** (request latency end to end through the
   core-network pods) — devices don't care that the cluster is "up," they care
   whether sessions time out.
3. **Scheduling/capacity saturation** — pending pods, per-AZ node CPU/memory. For
   a telco core, this predicts dropped sessions before they happen. The ceiling
   this metric is really watching for isn't node count — Karpenter handles that —
   it's **NAT Gateway throughput and ElastiCache connection/CPU limits**, neither
   of which autoscales on its own and both of which sit directly on the data
   path described in `NETWORK-DESIGN.md`.

**Logging/monitoring/alerting stack, in one call:** Amazon Managed Prometheus +
Grafana for Kubernetes-native metrics and dashboards; Fluent Bit shipping
container and VPC Flow Logs to OpenSearch for the SOC 2-retention audit trail;
CloudWatch stays for AWS-service-level signals (NAT, TGW, ElastiCache) rather than
forcing every signal through one tool.

---

## What I'd do next with more time

- Confirm whether the session-state client library is cluster-mode-aware before
  relying on ElastiCache's automatic failover claim as stated.
- Size NAT Gateway throughput against an actual traffic model rather than
  reasoning qualitatively about it as a ceiling.
- Pressure-test the EKS-vs-ECS call against the real per-workload networking
  requirement once that's confirmed component-by-component, not assumed
  hub-wide.
