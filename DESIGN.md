# Skylo Regional Hub — AWS Architecture Design (us-west-2)

## 0. Assumptions

- Two working diagrams back this doc: [`NetworkDesign.jpeg`](./NetworkDesign.jpeg) (network
  topology — subnets, route tables, TGW, DX/VPN) is authoritative for A1;
  [`SkyloDesignArchitecture.jpeg`](./SkyloDesignArchitecture.jpeg) (compute + registry-cache
  view) supplies the ECR/S3 endpoint detail folded into A1/A2. Where the two differ in emphasis,
  `NetworkDesign.jpeg` wins — it's the later, more complete iteration.
- One **Hub VPC per region** (`10.100.0.0/16` here), one regional **TGW** (`skylo-ground-tgw`)
  that is the single place both ground traffic (Direct Connect) and east-west Org traffic land.
- Ground stations reach us-west-2 over **two diverse 10Gbps Direct Connect circuits** into the
  TGW, with a **Site-to-Site VPN as backup** if both DX circuits fail. This closes what I'd
  flagged as the one unaddressed single point of failure in an earlier pass of this design — the
  diagram already has it, so I'm treating dual-DX + VPN as a hard requirement, not a stretch goal.
- The 3GPP core splits into two traffic classes with different infra needs: **UPF-class** (user
  plane — DPDK/SR-IOV/`hostNetwork`, multiple NICs) and **control-plane class** (AMF/SMF/session/
  API — stateless microservices). The diagram's single "EKS Cluster" box holds both; they're
  different node groups/taints underneath.
- The customer dashboard/API (443) is the one deliberately public surface. The diagram's public
  listener also lists 2152 (GTP-U) — I'm deliberately **not** enabling that by default; see A5.
- SOC 2 is already in scope org-wide; this doc adds the control mapping relevant to this hub.
- 3 AZs, matching the diagram. Traffic grows, but I'm designing for "scales cleanly," not a
  specific device count, since none was given beyond the diagram's own Karpenter/HPA ceilings.

---

## A1. Network

**Diagram:** [NetworkDesign.jpeg](./NetworkDesign.jpeg) — subnet tiers, route tables, NAT,
TGW/DX/VPN. Companion view for the ECR/S3 caching path:
[SkyloDesignArchitecture.jpeg](./SkyloDesignArchitecture.jpeg).

### Subnet tiers (VPC `10.100.0.0/16`, ×3 AZs)

| AZ | Public subnet | Private subnet |
|---|---|---|
| us-west-2a | `10.100.0.0/24` | `10.100.10.0/24` |
| us-west-2b | `10.100.1.0/24` | `10.100.20.0/24` |
| us-west-2c | `10.100.2.0/24` | `10.100.30.0/24` |

- **Public** — NAT Gateway (1/AZ) and the customer-facing NLB only. Nothing else lives here.
- **Private** — EKS worker nodes (Karpenter, 3–100/AZ), the TGW attachment ENI, and the ECR
  interface endpoint. No public IPs; egress via NAT, ground/Org reachability via TGW.
- **Pods** get their addresses from a **secondary, non-RFC1918 CIDR** (`100.64.0.0/10`, RFC 6598
  — I'd associate a concrete `100.64.0.0/16` slice of it) via VPC CNI custom networking + prefix
  delegation, not from the primary `/16`. This is what lets HPA scale pods 10→1,000/AZ without
  ever touching primary-subnet IP budget: node count and pod count scale on two separate address
  spaces, deliberately.

Two sizing/placement calls worth stating out loud, not just reading off the diagram:
- **TGW attachment shares the private subnets** rather than a dedicated `tgw-attach` tier — one
  fewer subnet type to operate. Trade-off: a dedicated tier gives cleaner route-table blast-radius
  separation. I'd add it the day a security review asks for it, not before.
- **Private subnets are `/24`, sized against the diagram's own stated ceiling.** Karpenter caps
  at 100 nodes/AZ; a `/24` gives 251 usable IPs/AZ, which covers that with real headroom (node
  ENIs + TGW ENI + interface-endpoint ENIs). I wouldn't draw it smaller — AWS subnets don't resize
  in place, so under-sizing here is a second migration later, not a quick fix.

### Route tables

- **Public** — one shared table across all 3 AZs: `0.0.0.0/0 → IGW`. Nothing else.
- **Private** — one table **per AZ**, never a shared cross-AZ table: default route to that AZ's
  *own* NAT Gateway, a route to `10.200.0.0/16` (ground) and Org CIDRs via the TGW attachment, and
  the S3 prefix-list route to the S3 Gateway endpoint. Own-AZ NAT only — a shared NAT across AZs
  is a cost optimization that quietly becomes a single point of failure, which fails "resilient to
  single-AZ failure" outright.

### Transit Gateway (`skylo-ground-tgw`)

- Carries the ground attachment today — `10.200.0.0/16`, over dual DX circuits with the VPN
  backup — and this VPC's attachment.
- **Extending the diagram:** the take-home also asks this attachment to carry east-west Org
  traffic, which isn't drawn yet. I'd add that as a **second, RAM-shared TGW route table**,
  separate from the ground route table — so a misbehaving Org account can't see ground-station
  traffic and vice versa. The segmentation is a TGW-level control, not "it's all in one VPC so
  it's fine."

### CIDR strategy — and how it avoids collisions as Skylo adds hubs

- A central IPAM allocates a fixed `/16` per hub, sequentially, from a reserved supernet —
  `10.100.0.0/16` is hub #1's VPC space; hub #2 gets `10.101.0.0/16`, and so on. The ground/on-prem
  side gets identical treatment from a **separate** reserved supernet (`10.200.0.0/16` is hub #1's
  ground segment). Two supernets, not one, so hub-VPC space and ground space can't collide with
  each other either.
- What actually prevents collisions is the range being **reserved in IPAM before the VPC exists**
  — not naming discipline at build time.
- The pod secondary CIDR is the one range exempt from this: prefix-delegated pod IPs never cross
  the TGW (cluster-local only), so every hub can safely reuse the *same* `100.64.0.0/16` slice
  without burning central IPAM budget on it. Worth stating explicitly so nobody "fixes" this later.

---

## A2. Compute

**Decision: EKS**, with **Karpenter** for node autoscaling (3–100 nodes/AZ) and **HPA** for pod
autoscaling (10–1,000 pods/AZ) — matching what the diagram already commits to.

- UPF-class pods need DPDK/SR-IOV, `hostNetwork`, and often a second/third NIC via Multus — EKS
  lets me run a custom CNI and SR-IOV device plugins as DaemonSets. ECS's networking model doesn't
  expose that layer on either launch type (Fargate or EC2).
- **Karpenter specifically, not cluster-autoscaler:** it provisions against the actual
  pending-pod resource shape instead of a fixed ASG shape — it matters here because UPF nodes and
  control-plane nodes want different instance types (network-optimized vs general compute), and a
  fixed ASG per type is exactly the rigidity Karpenter removes.
- Telco-core vendor software ships as Helm charts/Operators with CRDs, not ECS task definitions —
  fighting the ecosystem's packaging format is its own tax.
- Portability: Kubernetes travels if the same core stack needs to run at the edge or a second
  cloud later; ECS task definitions don't.

**Cost, stated honestly:** EKS is a heavier operational surface — control-plane version upgrades,
add-on management (CoreDNS, VPC CNI + prefix-delegation config, Karpenter, cert-manager), a real
on-call skill requirement that ECS mostly hides. Accepting that because the workload's networking
needs make it non-negotiable, not because Kubernetes is fashionable.

**What would reverse this:** if this hub's scope turned out to be **only the stateless
control-plane services** (AMF/SMF/API — no DPDK, no `hostNetwork`) with UPF centralized elsewhere,
I'd run that slice on ECS/Fargate and drop the operational overhead substantially. The reversing
question is specifically *"does this hub run the packet-processing UPF, or only session/control
logic."*

---

## A3. Storage

| Need | Service | Why |
|---|---|---|
| Short-term session state (high throughput, low latency) | **ElastiCache (Redis/Valkey), cluster mode, multi-AZ** | In-memory reads for UPF/session lookups, native TTL for session expiry, multi-AZ replication gives failover without app-level handling. |
| Long-term archival of connection logs | **S3, Standard → Intelligent-Tiering/Glacier lifecycle, Object Lock** | Durable and cheap at connection-log volume; Athena/Glue queries it directly for SOC 2 evidence pulls; Object Lock gives auditors immutability without a second product. |

Worth distinguishing: the diagram's other S3 bucket is a **container-image layer cache** (ECR
pulls routed via the S3 Gateway endpoint, avoiding NAT egress cost/hops for image pulls) — a
different, much smaller bucket than the connection-log archive above. Same service, two unrelated
jobs; one lifecycle/retention policy should not govern both.

---

## A4. HA and DR

**AZ loss:** every stateful/stateless component is 3-AZ by default — Karpenter node groups spread
across AZs (topology spread constraints + PodDisruptionBudgets, so a drain doesn't take a service
down), NAT Gateway per AZ, ElastiCache multi-AZ with automatic failover, NLB cross-zone. Each AZ
runs at ≤65–70% of its own capacity at steady state, so losing one AZ pushes the remaining two to
full, not over — failover doesn't turn an AZ outage into a capacity outage.

**Ground-link loss:** dual Direct Connect circuits into the TGW, Site-to-Site VPN as backup if
both fail — this is the diagram closing what was previously this design's one unaddressed single
point of failure (a single DX location). Worth confirming in review that the two DX circuits
terminate at physically diverse facilities, not just diverse ports at the same one — logical
redundancy on top of a shared physical failure domain isn't real redundancy.

**Region loss (all of us-west-2 gone):** this hub is tied to physical ground infrastructure
in-region — devices reaching this continent's ground stations can't transparently fail over to a
hub on another continent without materially worse latency, and possibly a data-residency
conversation. So this is **warm standby, not active-active**:

- Infra is IaC, so a second region stands up from the same Terraform.
- S3 cross-region replication for log archives; ElastiCache backups restorable in the standby
  region.
- Target **RTO ~2–4 hours** (re-provision EKS + core, restore state, re-point DX or fail ground
  traffic to a backup path), **RPO ~5–15 minutes** (bounded by async replication lag).
- Named trade-off: active-active pushes RTO toward zero but roughly **doubles steady-state spend**
  and adds the burden of keeping two live core stacks continuously in sync. Not adopting that by
  default without a specific SLA from Skylo that requires it — a judgment call, not a technical
  limitation.

- **Cache-only middle ground:** ElastiCache (Redis/Valkey) Global Datastore gives real-time cross-region replication (sub-second lag) for session state specifically, without touching anything else in the stack — the extra spend is scoped to a second live cache cluster, not a second live core stack. This tightens session-state RPO close to zero without paying the full active-active tax across EKS/network/etc. I'd adopt it if Skylo needs session continuity across a region loss specifically; not defaulting to it because nothing else in the path is real-time-replicated, so overall RTO stays dominated by EKS/network re-provisioning regardless — a faster cache alone doesn't move the number that matters.
---

## A5. Security and Observability

**IAM role model:** IRSA (or EKS Pod Identity) — every workload gets its own role scoped to
exactly what it calls, never the node's instance role. Deliberately withheld from workload roles:

- Any wildcard (`*`) action or resource.
- `iam:PassRole` / `iam:CreateRole` — workloads never mint or hand off identity.
- Rights to modify security groups, route tables, or TGW attachments — network stays
  platform-owned; a compromised pod can't widen its own network access.
- Cross-account `sts:AssumeRole` beyond the one or two roles a service actually needs.

**The SG model, tied to the diagram:** `sg-nlb-public` is the *only* internet-facing security
group in the hub. `sg-eks-private` (EKS nodes) allows inbound only from `sg-nlb-public`'s ID and
the ground/Org CIDRs via TGW — never a `0.0.0.0/0` rule on EKS itself. **One deliberate change
from the diagram:** the public listener also lists 2152/GTP-U — I'd keep that **off by default**
and DX-only, since unauthenticated GTP-U on the open internet is a known telco anti-pattern. I'd
only enable it for a genuine non-DX device path (e.g., a roaming/interconnect partner), and even
then behind IPsec, not a bare UDP listener.

**First 3 AWS security services, in order:**

1. **AWS Config** — the evidence engine: continuous resource recording + managed rules is most of
   what a SOC 2 auditor asks to see, and it catches IaC drift from the baseline.
2. **GuardDuty** — VPC Flow Logs/DNS/CloudTrail/EKS audit log threat detection with near-zero
   setup cost; the "did something bad actually happen" signal Config doesn't give.
3. **Security Hub** — aggregates Config + GuardDuty (+ Inspector once workloads run) into one
   CIS/AWS-FSBP-mapped view, instead of three consoles nobody checks.

**Top 3 metrics to alert on:**

1. Pod crash-loop/OOMKilled rate — earliest signal something is actually broken, not just slow.
2. P99 session-processing latency (GTP-U path for UPF, request latency for control-plane) —
   devices don't care the cluster is "up," they care whether sessions time out.
3. Scheduling/capacity saturation — pending pods, per-AZ node CPU/memory. For a telco core this
   predicts dropped sessions before they happen. The ceiling this metric is really watching for
   isn't node count — Karpenter handles that — it's **NAT Gateway throughput and ElastiCache
   connection/CPU limits**, neither of which autoscales on its own.

**Logging/monitoring stack, one call:** Prometheus (Amazon Managed Prometheus) + Grafana for
Kubernetes-native metrics and dashboards; Fluent Bit shipping container and VPC Flow Logs to
OpenSearch for the SOC 2-retention audit trail and ad hoc investigation; CloudWatch stays for
AWS-service-level signals (NAT, TGW, ElastiCache) rather than forcing every signal through one
tool.

---

## What I'd do next with more time

- Model actual packet/session rates to size node groups, NAT Gateway bandwidth, and ElastiCache
  instead of reasoning qualitatively.
- Confirm the two DX circuits are physically diverse (different facilities/providers), not just
  logically redundant.
- Threat-model the customer-facing NLB path specifically — it's the one deliberately public
  surface, and the one place I overrode the diagram outright (dropping public GTP-U) rather than
  just describing what's drawn.
