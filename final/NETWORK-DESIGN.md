# Skylo Regional Hub — Network Design (us-west-2)

**Scope note:** this document covers Deliverable A's network section only (subnet
tiers, route tables, NAT, the Transit Gateway attachment, and CIDR strategy), plus a
worked data-flow example and the end-to-end service-time budget referenced in the
interview slides. HA/DR is intentionally out of scope for this artifact — see the
scope note at the end of `DESIGN.md`.

**Diagram:** [`network-design.png`](./network-design.png)

---

## 1. Topology

One **Hub VPC per region** (`10.100.0.0/16` for us-west-2), attached to one regional
**Transit Gateway** (`skylo-ground-tgw`, RAM-shared from the network account) that
is the single place both Direct-Connect ground traffic and east-west Org traffic
land — as a **variable/data source**, not a resource this VPC owns.

### Subnet tiers (`10.100.0.0/16`, ×3 AZs)

| AZ | Public subnet | Private subnet |
|---|---|---|
| us-west-2a | `10.100.0.0/24` | `10.100.10.0/24` |
| us-west-2b | `10.100.1.0/24` | `10.100.20.0/24` |
| us-west-2c | `10.100.2.0/24` | `10.100.30.0/24` |

- **Public** — one NAT Gateway per AZ and the public NLB target group only. Nothing
  else lives here, and subnets don't auto-assign public IPs (NAT/NLB get explicit
  EIPs). This is a deliberate blast-radius boundary: the public tier has no route
  to ground or org CIDRs at all (see route tables below).
- **Private** — EKS worker nodes, the TGW attachment ENIs, and all pods. No public
  IPs; egress is via NAT, ground/Org reachability is via the TGW.
- **No dedicated `tgw-attach` subnet tier.** The attachment ENIs land in the private
  subnets. Trade-off, stated plainly: a dedicated tier gives cleaner route-table
  blast-radius separation between "workload" and "transit" traffic. I'd add it the
  day a security review asks for it, not before — one fewer subnet type to operate
  until then.
- **Private subnets are `/24`.** Compute scales with traffic per the constraint, and
  a `/24` gives 251 usable IPs/AZ — enough for node ENIs, the TGW attachment ENI, and
  headroom, without a second migration later (AWS subnets don't resize in place).
- **Pods get their addresses from a secondary, non-RFC1918 CIDR** (`100.64.0.0/10`,
  RFC 6598 — a `100.64.0.0/16` slice associated at the VPC level) via VPC CNI custom
  networking + prefix delegation, not from the primary `/16`. Node count and pod
  count then scale on two separate address spaces — pod autoscaling never touches
  the primary-subnet IP budget.

### Route tables

- **Public** — one table shared across all 3 AZs: `0.0.0.0/0 → IGW`. Nothing else.
- **Private** — one table **per AZ**, never shared cross-AZ: default route to that
  AZ's *own* NAT Gateway, plus a route to the ground supernet and the org supernet
  via the TGW attachment (both below). Own-AZ NAT only — a shared NAT across AZs is
  a cost optimization that quietly becomes a single-AZ-failure single point of
  failure, which directly fails the "resilient to single-AZ failure" constraint.

### Transit Gateway attachment — two route tables, not one

The take-home asks this one attachment to carry **both** Direct-Connect ground
traffic **and** east-west Org traffic. Putting both on one flat TGW route table
means any org account that can reach the TGW can also reach the ground segment (and
vice versa) — that's not "zero-trust," it's "one VPC's worth of trust with extra
steps." So the TGW attachment is paired with **two separate, purpose-built route
tables**:

| Route table | Carries | Never carries |
|---|---|---|
| `Ground` | `10.128.0.0/9` (ground supernet) ⇄ hub VPC | Org account traffic |
| `Org East-West` | `172.16.0.0/12` (org supernet) ⇄ hub VPC | Ground-station traffic |

This is drawn explicitly in the diagram (not just asserted in prose) — a
misbehaving org account genuinely cannot see ground-station traffic, because there
is no route table that carries both. The segmentation is enforced at the TGW, not
by "it's all in one VPC so it's fine."

---

## 2. CIDR strategy — and how it avoids collisions as Skylo adds hubs

Three **disjoint address families**, not three ranges carved from the same block:

| Address family | Range | Allocation |
|---|---|---|
| Hub VPCs | `10.0.0.0/9` | one `/16` per hub, sequential from central IPAM. This hub (#1, us-west-2): `10.100.0.0/16`. Hub #2 → `10.101.0.0/16`. |
| Ground segments | `10.128.0.0/9` | one `/16` per hub's ground side, sequential. This hub's ground segment: `10.200.0.0/16`. |
| Org / shared-services accounts | `172.16.0.0/12` | a **different RFC1918 block entirely** — not a sub-range of the `10.0.0.0/8` space used above. |
| Pod secondary CIDR | `100.64.0.0/10` (RFC 6598) | cluster-local only, never routed over the TGW — every hub reuses the *same* slice with zero collision risk, since it never leaves the cluster. |

**Why this closes the collision question for good, not just for today:** hub VPCs
and ground segments are two halves of the same `/8` (`10.0.0.0/9` vs
`10.128.0.0/9`) — deliberately chosen so neither range can ever grow into the
other. Org accounts sit in a *different* RFC1918 block altogether
(`172.16.0.0/12`), so no amount of hub growth can ever collide with org space
either. That's a structural property, not a naming convention someone has to
keep enforcing correctly — the three families simply can't grow into each
other. Adding hub #37 tomorrow cannot collide with any existing hub's ground
segment or any org account, by construction.

---

## 3. Worked example — how data actually flows, ground source to customer

Diagram: [`architecture-dataflow.png`](./architecture-dataflow.png)

A concrete walk-through of one request, referenced against the diagram's numbered
steps:

1. **Ground source system.** A satellite ground station (or an IoT device behind
   it) generates connectivity data — session setup, telemetry, routing info — and
   sends it toward the hub over the ground segment (`10.200.0.0/16`), which is
   physically outside AWS.
2. **Direct Connect → Transit Gateway.** The data arrives over the single Direct
   Connect circuit into `skylo-ground-tgw`. It only ever touches the **Ground**
   route table — there is no path from here into org-account space.
3. **TGW attachment → private subnet → data-ingress pods.** The TGW attachment ENI
   (one per AZ, no dedicated tier) hands the traffic to whichever AZ's private
   subnet it lands in. EKS worker nodes there run the **data-ingress pods**, which
   receive and normalize the incoming connectivity data.
4. **Core-network processing pods.** The normalized data is handed to the
   **core-network pods** — the containerized 3GPP core components — which manage
   the device's session state (read/write against ElastiCache, in-memory,
   effectively sub-millisecond) and decide how to route the result.
5. **Public NLB.** Any response bound for a customer-facing application leaves
   through exactly one place: the public NLB. No pod, and no other component in
   this VPC, is internet-reachable — this is the one deliberate public surface, and
   it's the only one.
6. **Internet Gateway → internet → customer.** The NLB hands off to the IGW, and
   from there the customer's application or device receives the response over the
   open internet.

### End-to-end service-time budget

| Hop | Segment | Typical order of magnitude | Notes |
|---|---|---|---|
| 1 → 2 | Ground station → Direct Connect → TGW | **~5–30 ms** | Dominated by physical backhaul distance to the nearest DX location — this is Skylo's terrestrial link, not something this hub's AWS design controls. |
| 2 → 3 | TGW attachment → private subnet | **~1–2 ms** | A single AWS-managed hop, same region. |
| 3 → 4 | Data-ingress pods → core-network pods | **< 1 ms** | In-VPC, typically same AZ. |
| 4 | Core-network processing itself | **workload-dependent** | Application/session logic — deliberately *not* folded into the network number below; conflating the two is how illustrative figures get mistaken for measured SLIs. |
| 4 → 5 | Core-network pods → NLB | **< 1 ms** | In-VPC, typically same AZ. |
| 5 → 6 | NLB → IGW → internet → customer | **~20–100+ ms** | Dominated by the customer's own network distance and access path — outside this hub's control. |

**AWS-managed network hops total (2→5): ~3–5 ms.** Everything else in the
end-to-end number — the ground backhaul and the customer's internet path — is
determined by geography and terrestrial/last-mile links, not by anything this
design can shorten. These figures are stated as **order-of-magnitude engineering
estimates from AWS's published component characteristics, not benchmarked
numbers** — worth saying explicitly if an interviewer asks "where does that
number come from."

---

## 4. What I'd do next with more time

- Confirm actual DX location and expected backhaul distance per ground station to
  replace the `~5–30 ms` range with a real number.
- Load-test the TGW-attachment-in-private-subnet choice against a dedicated
  `tgw-attach` tier once traffic volume is known, rather than assuming the
  trade-off holds indefinitely.
- Get the org supernet (`172.16.0.0/12`) confirmed against Skylo's actual AWS
  Organization IPAM pool rather than assumed as a clean slate.
