# Skylo Regional Hub — AWS Architecture Design (us-west-2)

## 0. Assumptions

- One **Hub VPC per region**, one **regional TGW** attached to it. The TGW is shared to other
  Skylo Org accounts via AWS RAM (hub-and-spoke, not a VPC-peering mesh) and is the single
  place both Direct Connect (ground stations) and east-west Org traffic land.
- Ground stations reach us-west-2 over a **DX private VIF → DX Gateway → Transit VIF
  association to the regional TGW** — this is a private path end to end, no internet transit.
- The 3GPP core splits into two traffic classes with different needs: **UPF-class** (user
  plane — high packet-per-second, needs DPDK/SR-IOV/hostNetwork, multiple NICs) and
  **control-plane class** (AMF/SMF/session/API — standard stateless microservices).
- A thin **customer-facing dashboard/API** exists and needs a real internet entry point;
  everything else is private-only. This is the one deliberately public surface.
- SOC 2 is already in scope org-wide (this doc adds the control mapping relevant to this hub,
  not a full SOC 2 program).
- 3 AZs available in us-west-2. Traffic grows, but the initial hub does not need to be
  hyperscale — I'm designing for "scales cleanly," not for a specific number of devices,
  since none was given.

---

## A1. Network

### Topology (ASCII)

```
                              Skylo AWS Organization
                    ┌───────────────────────────────────────────┐
                    │   Other accounts (shared svcs, security,   │
                    │   other regional hubs) — via RAM-shared TGW │
                    └───────────────┬─────────────────────────────┘
                                    │  TGW route table: "org-east-west"
 Ground Stations                   │
      │  DX private VIF            │
      ▼                            ▼
 ┌─────────────┐    Transit    ┌─────────────────────┐
 │ DX Gateway   │──── VIF ────▶│  Regional TGW         │
 └─────────────┘               │  (2 route tables:     │
                                │   ground | org-e-w)   │
                                └──────────┬────────────┘
                                           │ TGW attachment (1 subnet/AZ)
                     ┌─────────────────────┴─────────────────────┐
                     │            Hub VPC  10.30.0.0/16           │
                     │                                            │
   AZ-a  ┌───────────┼────────────┐  AZ-b (same tiers)  AZ-c ...  │
         │ tgw-attach │ 10.30.0.0/24                              │
         │ private-app│ 10.30.16.0/20  — EKS nodes / UPF pods     │
         │ private-data│10.30.32.0/20 — ElastiCache, VPC endpoints │
         │ public-edge│ 10.30.48.0/24 — NAT GW + customer NLB only │
         └────────────┴────────────┘
                     │
                 IGW (public-edge only)
```

### Subnet tiers (×3 AZs)

| Tier | Purpose | Internet? |
|---|---|---|
| `tgw-attach` | TGW ENI per AZ | No |
| `private-app` | EKS worker nodes, UPF + control-plane pods | No (NAT for egress only) |
| `private-data` | ElastiCache, interface VPC endpoints (ECR, S3, STS, CloudWatch) | No |
| `public-edge` | NAT Gateway (1/AZ) + the one customer-facing NLB | Yes, via IGW |

Route tables are per tier, per AZ: private tiers default-route to that AZ's own NAT Gateway
(never a shared cross-AZ NAT — that's a single point of failure disguised as a cost saving),
plus a static route for ground and Org CIDRs pointed at the TGW attachment. The public-edge
table routes `0.0.0.0/0` to the IGW and nothing else.

**TGW route tables are split in two**, not one flat table: a `ground` route table (DX-origin
traffic only reaches the subnets that need it) and an `org-east-west` route table (Org
accounts see only what's explicitly shared). This is the actual security control here —
segmentation at the TGW, not just "everything's in a VPC so it's fine."

### CIDR strategy

- Central **IPAM** (or at minimum a spreadsheet acting as one, day one) owns a supernet per
  continent, e.g. `10.16.0.0/12` for Americas hubs. Each regional hub is allocated a fixed
  `/16` sequentially out of that block — us-west-2 gets `10.30.0.0/16` here.
- Hubs **do not get routes to each other by default.** A new hub is just a new non-overlapping
  `/16` plus a new TGW attachment to the shared TGW (or its own TGW peered up); it never has to
  negotiate CIDR space with an existing hub because the allocation is centrally reserved before
  the VPC is created. That's what actually prevents collisions as Skylo adds hubs — not
  discipline at build time, but the range being spoken for in advance.
- Subnets are sized generously (`/20`–`/24`) with room to add a 4th AZ or split a tier later
  without re-carving the VPC.

---

## A2. Compute

**Decision: EKS.**

Justification against the actual workload, not compute in the abstract:

- UPF-class pods need DPDK/SR-IOV, `hostNetwork`, and typically a second/third NIC via Multus
  — that requires controlling the CNI stack and kubelet device plugins. EKS lets me run a
  custom CNI (VPC CNI + Multus, or swap to Cilium) and SR-IOV device plugins as DaemonSets.
  ECS does not expose this layer — not on Fargate, and not meaningfully on EC2 launch type
  either, since ECS's networking model doesn't support attaching multiple pod-level ENIs with
  custom drivers.
- Telco-core vendor software (Open5GS/free5GC-style cores, and most commercial 3GPP vendors)
  ships as Helm charts / Kubernetes Operators with CRDs, not ECS task definitions. Fighting the
  packaging format the ecosystem ships in is its own tax.
- Portability: if Skylo ever needs the same core stack to run at the edge or on a second cloud,
  Kubernetes travels; ECS task definitions don't.

**What this costs, honestly:** EKS is a heavier operational surface — control plane version
upgrades, add-on management (CoreDNS, CNI, Karpenter/cluster-autoscaler, cert-manager,
ingress), and a real on-call skill requirement that ECS mostly hides. I'm accepting that
overhead because the workload's networking requirements make it non-negotiable, not because
Kubernetes is fashionable.

**What would make me reverse this:** if the region-1 scope turned out to be **only the
stateless control-plane services** (AMF/SMF/API, no DPDK, no hostNetwork) with UPF staying
centralized elsewhere — i.e., if "core network processing" here didn't actually include the
user-plane workload — I'd run that slice on ECS on Fargate and cut the operational overhead
substantially. The requirement that reverses the decision is specifically *"does this hub run
the packet-processing UPF, or only session/control logic."*

---

## A3. Storage

| Need | Service | Why |
|---|---|---|
| Short-term session state (high throughput, low latency) | **ElastiCache (Redis/Valkey), cluster mode, multi-AZ** | In-memory reads for UPF/session lookups, native TTL for session expiry, and multi-AZ replication gives failover without the application handling it. |
| Long-term archival of connection logs | **S3, Standard → Intelligent-Tiering/Glacier lifecycle, Object Lock enabled** | Durable and cheap at the volume connection logs accumulate to; Athena/Glue query it directly for SOC 2 evidence pulls; Object Lock gives the immutability auditors ask for without a second product. |

---

## A4. HA and DR

**Single-AZ loss:** every stateful and stateless component is 3-AZ by default — EKS nodes
spread across AZs (topology spread constraints + PodDisruptionBudgets so a drain doesn't take
a whole service down), NAT Gateway per AZ, ElastiCache multi-AZ with automatic failover, and
the customer NLB is cross-zone. Each AZ's node group is sized so it runs at roughly ≤65-70% of
its own capacity at steady state — losing one AZ pushes the remaining two to full but not over,
so failover doesn't turn an AZ outage into a capacity outage.

**Region loss (all of us-west-2 gone):** I'm treating this as a hub tied to physical ground
infrastructure in that region — devices connecting to satellites serving this continent can't
transparently fail over to a hub on another continent without materially worse latency, and
possibly a data-residency conversation. So this is **warm-standby, not active-active**:

- Infra is IaC, so a second region can be stood up from the same Terraform.
- S3 cross-region replication for connection-log archives; ElastiCache backups restorable in
  the standby region.
- Target **RTO ~2–4 hours** (re-provision EKS + core via Terraform, restore state, re-point DX
  or fail ground traffic to a backup path), **RPO ~5–15 minutes** (bounded by async
  replication lag).
- Cost trade-off, stated explicitly: true active-active would push RTO toward zero but roughly
  doubles steady-state infrastructure spend and adds the operational cost of keeping two live
  core stacks continuously in sync. I wouldn't default to that without a specific SLA from
  Skylo that requires it — this is a judgment call, not a technical limitation.

---

## A5. Security and Observability

**IAM role model:** IRSA (or EKS Pod Identity) — every workload gets its own IAM role scoped to
exactly what it calls, not the node's instance role. Deliberately withheld from workload roles:

- Any wildcard (`*`) action or resource.
- `iam:PassRole` / `iam:CreateRole` — workloads never mint or hand off identity.
- Ability to modify security groups, route tables, or TGW attachments — network is
  platform-owned, not app-owned. This is the actual separation-of-duties control: a compromised
  pod can't widen its own network access.
- Cross-account `sts:AssumeRole` beyond the one or two specific roles a service actually needs.

**First 3 AWS security services, in this order:**

1. **AWS Config** — turned on first because it's the evidence engine: continuous resource
   recording plus managed rules is most of what a SOC 2 auditor actually asks to see, and it
   also catches config drift from the IaC baseline.
2. **GuardDuty** — VPC Flow Logs / DNS / CloudTrail / EKS audit log threat detection with
   essentially no setup cost; this is the "did something bad actually happen" signal Config
   doesn't give you.
3. **Security Hub** — aggregates Config + GuardDuty (+ Inspector once workloads are running)
   into one prioritized view mapped to CIS/AWS FSBP, so there's one dashboard instead of three
   consoles nobody checks.

**Top 3 metrics to alert on:**

1. Pod crash-loop / OOMKilled rate — earliest signal something is actually broken, not just
   slow.
2. P99 session-processing latency (GTP-U path latency for UPF specifically, request latency for
   control-plane services) — this is the end-user-facing signal; devices don't care that the
   cluster is "up," they care whether sessions are timing out.
3. Scheduling/capacity saturation — pending pods and per-AZ node CPU/memory pressure. For a
   telco core, this metric predicts dropped sessions before they happen, so it's the
   early-warning one, not a lagging indicator.

**Logging/monitoring stack (one call, not a survey):** Prometheus (via Amazon Managed
Prometheus) + Grafana for Kubernetes-native metrics and dashboards, Fluent Bit shipping
container and VPC Flow logs to OpenSearch for the SOC 2-retention audit trail and ad hoc
investigation. CloudWatch stays as the AWS-service-level signal (NAT, TGW, ElastiCache metrics)
rather than trying to force every signal through one tool.

---

## What I'd do next with more time

- Model actual expected packet/session rates to size node groups and ElastiCache instead of
  reasoning qualitatively.
- Decide the DX resiliency story explicitly (single DX location is a real single point of
  failure that this doc hasn't sized a fix for — second DX location or VPN backup).
- Threat-model the customer-facing NLB path specifically, since it's the one deliberately
  public surface.
