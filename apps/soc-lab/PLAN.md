# SOC Lab — planning doc (no manifests yet)

Status: **planning only**. Nothing in this directory is deployed or wired into `apps/kustomization.yaml`.
This file exists so a future session (or future you) has the reasoning, not just the YAML, once it's built.

## Goal

Attack-and-defend scenarios for building cloud + cybersecurity skills, aimed at both the job search
(write-ups usable as portfolio pieces alongside `shubhrajitpallob.dev`) and later certification study
(CySA+/OSCP-shaped exercises). Two roles run side by side: a defender side (SIEM, detection rules) and
an attacker side (vulnerable targets, offensive tooling), with scenarios designed to generate signal the
defender side has to notice and triage.

## The decision that shapes everything: same cluster, isolated namespaces

The safer default is a fully separate environment — different hardware or network segment, no shared
blast radius with anything reachable from the internet. That was offered and turned down in favor of
reusing the existing 3-node cluster, for cost. That's a reasonable trade for a homelab, but it means the
lab shares fate with the public portfolio and the K3s control plane unless the following are treated as
mandatory, not optional:

1. **Never share the public ingress path.** The portfolio uses the Cloudflare tunnel's unauthenticated
   `web` entrypoint. No lab hostname is ever published on that tunnel. Any lab UI (a SIEM dashboard, a
   scoreboard) follows the pattern already used for ArgoCD and Grafana: a Traefik `IngressRoute` on
   `websecure` with the wildcard cert, reachable only over Tailscale, or — if it must be public —
   `websecure` behind a Cloudflare Access policy the same way. Never the bare tunnel route.
2. **Default-deny NetworkPolicy per lab namespace**, same shape as `apps/portfolio/networkpolicy.yaml`:
   deny all ingress by default, then explicit allows. Attacker and target namespaces additionally get a
   **default-deny egress** policy, so a compromised or intentionally-vulnerable pod cannot reach the
   internet, the `portfolio` namespace, or anything outside its own scenario's namespaces. Only the
   traffic a scenario specifically needs (e.g. attacker → target on one port) is allowed.
3. **A `ResourceQuota` and `LimitRange` on every lab namespace, no exceptions.** This is the direct lesson
   from the 2026-09-27 outage: that incident was a control-plane API/etcd overload, not a workload one,
   but the fix is the same principle — nothing in this cluster gets to consume unbounded resources again.
   A quota also caps the blast radius of a scenario that misbehaves (a fork bomb inside a vulnerable
   container, a noisy attacker tool) to its own namespace.
4. **Pod Security Admission, scoped per namespace, not cluster-wide.** `restricted` on the SIEM/attacker
   infrastructure namespaces; a deliberately looser label only on the namespace holding the vulnerable
   targets themselves (many vulnerable-by-design images need old capabilities or root to reproduce their
   CVE), and that namespace is exactly the one with default-deny egress and the tightest quota.
5. **Its own ServiceAccounts, no `cluster-admin`.** Lab tooling gets namespace-scoped RBAC. Nothing in the
   lab is ever given a token that can touch `argocd`, `cert-manager`, or `portfolio`.
6. **Node placement stays deliberate.** `server-1` (control plane, tainted) never runs lab pods — only
   `node-exporter` tolerates that taint today, and that should stay the only exception. Once the node
   upgrade/second worker exists, prefer keeping lab workloads off whichever node runs the portfolio's
   required affinity (`agent-1` today), so a lab incident can't take the public site down as a side effect.

None of this is exotic — it's the same conventions this repo already uses for `apps/portfolio`, applied
consistently. The difference is that here they're load-bearing for safety, not just tidiness.

## Resource reality check

The existing `apps/monitoring/ELK/` stack (parked, ~2.6 GiB of requests) is the obvious SIEM candidate —
Elasticsearch + Kibana + Logstash + Filebeat already exist as manifests. But it was parked specifically
because it doesn't fit today's ~5.5 GiB of free worker RAM alongside everything else. The SOC lab doesn't
remove that constraint, it adds to it: portfolio (~0.2 GiB) + kube-prometheus-stack (~1.5 GiB, still
parked) + a SIEM (~1–2.6 GiB depending on which one) + targets + attacker tooling (budget another
~0.5–1 GiB) doesn't fit on two small/flaky workers. Realistically this needs either the resize discussed
for `server-1` to *also* extend to a real worker node, or a dedicated additional node once the current
node-upgrade work lands. Don't provision the lab's SIEM until that capacity exists — check `kubectl top
nodes` against a real budget the same way `apps/monitoring/prometheus/values.yaml` was sized, not against
hope.

Cheaper SIEM alternative worth considering instead of full ELK: **Wazuh** (lighter single-binary-ish
footprint) or a Loki+Promtail-based log pipeline riding on top of the (also parked) kube-prometheus-stack
Grafana, so dashboards and alerts live in one place. Decide this in Phase 1, once real capacity numbers
exist post-upgrade.

## Scenario shape (cloud + cybersecurity, not just generic pentest)

Given the job-search angle is cloud/DevOps, scenarios should lean toward Kubernetes- and cloud-native
attack surface, not only classic web/OS vulnerabilities:

- **Classic web/app targets** (DVWA, OWASP Juice Shop, WebGoat) — cheap, well-documented, good for
  detection-rule practice (SQLi, XSS, auth bypass) with a SIEM watching.
- **Kubernetes-specific scenarios** — a deliberately misconfigured namespace (over-broad RBAC, a Secret
  mounted where it shouldn't be, an exposed Dashboard-equivalent), then use `kube-hunter` as the attacker
  tool and `kube-bench`/`kubeaudit` on the defender side to find and fix what `kube-hunter` found. This is
  the most portfolio-relevant category given the target job market.
- **Container escape / image scenarios** — a vulnerable base image, privilege escalation inside a pod,
  detected via runtime tooling (Falco is the standard choice, budget its footprint before adding it).
- **Cloud misconfiguration scenarios** in the AWS account (see "AWS: budget and account lifetime"
  below) — an intentionally over-permissive IAM policy or public S3 bucket, found and remediated. Scenario
  details are yours to fill in; the section below only covers cost and account guardrails.

Each scenario should produce: an attacker-side walkthrough, the defender-side detection (a SIEM rule or
dashboard panel that would have caught it), and a short write-up. The write-ups are the actual job-search
artifact — the running lab is the practice, not the deliverable.

## AWS: budget and account lifetime

The account has $200 of Free Tier credits. The constraints (AWS Free Tier FAQ, accounts opened after
2025-07-15) decide how they should be used:

- **The free plan ends at 6 months, or earlier if the credits run out, and the account then closes.**
  Resources become inaccessible; data is kept only 90 days. Upgrading to the paid plan keeps the account and
  keeps unused credits until they expire **12 months after sign-up**.
- **Never upgrade by joining an AWS Organization or setting up Control Tower**: that expires the credits
  immediately. Upgrade from the account's own billing page if the lab should outlive month 6.
- GuardDuty and Security Hub are **30-day trials**, not free. Enable them only for the window when
  scenarios are actually running, so the trial covers real practice rather than an idle account.

### Decision: AWS is lab-only, not production

The earlier idea of moving the K3s control plane to AWS is dropped. A 24/7 instance sized for the control
plane (~t3.medium: roughly $30/month compute, plus ~$3.65/month for its public IPv4 and a few dollars of EBS)
would spend most of the $200 inside the 6-month window, leave nothing for the lab, and put the cluster's
control plane on an account that closes itself. **The control-plane upgrade happens on Interserver**; AWS
credits go to lab resources that are created for a session and destroyed afterwards.

### Cost guardrails (set these up before creating anything else)

1. **Secure the account first**: MFA on the root user, then stop using root; do lab work as a separate IAM
   identity. Never put AWS access keys in this repo (it is public).
2. **AWS Budgets** with email alerts at e.g. $25, $50, $100 of actual spend, plus a forecast alert. Setting
   up a budget is also one of the onboarding activities that earns part of the extra $100 credit.
3. **Everything as code, destroyed after each session.** Infrastructure is defined in Terraform (or
   CloudFormation) so a scenario can be torn down completely and rebuilt from nothing. Terraform state and
   `*.tfvars` are gitignored; state can hold sensitive values.
4. **Known cost traps to avoid**: NAT Gateways (~$33/month each just to exist), idle public IPv4 addresses,
   forgotten EBS volumes/snapshots, leaving AWS Config recording continuously, and leaving GuardDuty/Security
   Hub on past their trials. Check the Billing console's per-service breakdown after every session.
5. **One region only** (e.g. `us-east-1`), so nothing is left running in a region you never look at.

### Rough budget (to be revised against the real bill)

| Item | Approx. cost | Notes |
|---|---|---|
| CloudTrail management-event trail to S3 | ~$0–1/month | first copy of management events is free; S3 storage is tiny |
| Scenario infrastructure, created and destroyed per session | ~$1–5/session | depends on the scenario; destroy the same day |
| GuardDuty / Security Hub | $0 during trials | small but non-zero afterwards on a quiet account; disable between sessions |
| Optional on-demand lab worker (see below) | ~$5–10/month | only if stopped between sessions; EBS is billed while stopped |

Target: stay under ~$25/month, which leaves a buffer inside $200 over 6 months.

### Getting AWS signal into the homelab SIEM

The SIEM stays in the homelab (permanent, not bound to the credit window). CloudTrail and, when enabled,
GuardDuty findings are written to an S3 bucket, and the SIEM pulls them with a **read-only IAM identity
scoped to that one bucket** (Wazuh has a built-in AWS S3 module for this; Loki/ELK can do the same with a
shipper). The credentials live only as a hand-created cluster Secret, like the others listed in CLAUDE.md.
This keeps the hybrid simple: no VPN or peering between AWS and the cluster is needed for log collection.

### Optional: an on-demand AWS lab worker

The resource reality check below is the lab's biggest blocker. An EC2 instance (e.g. t3.large, 8 GiB)
joined to the cluster over Tailscale, **tainted so only lab workloads run on it**, and **stopped between
sessions** would give the lab its own node without adding permanent cost. It also strengthens isolation:
anything that escapes a container lands on a disposable machine, not on `agent-1` or `shubmedia`.
Conditions: only after the Interserver control-plane upgrade (a joining node adds load to the control
plane); a security group with **no inbound rules** (Tailscale connects outbound; use SSM Session Manager
instead of SSH); and accept that lab pods go Pending while it is stopped. Decide in Phase 1.

## Phased roadmap

- **Phase 0 (now, while waiting on the node upgrade — no lab pods yet):** write this plan (done), decide
  the SIEM choice, write the namespace/NetworkPolicy/ResourceQuota manifests as code and validate them
  with `kubectl kustomize` / dry-run the same way every other component in this repo is validated, but
  don't apply them yet. Pick the first 2–3 scenarios and write their walkthroughs in the abstract.
  **AWS side:** secure the account and set up the budget alerts (cost guardrails 1–2) now; they cost
  nothing and the 6-month clock is already running. Create no other resources yet.
- **Phase 1 (after the node upgrade lands and `kubectl top nodes` shows real headroom):** stand up the
  namespaces, quotas and policies first, empty. Confirm the isolation actually holds (a throwaway pod in
  another namespace must fail to reach the lab, exactly like the NOT YET TESTED note on
  `apps/portfolio/networkpolicy.yaml`, but tested this time before anything sensitive runs). Then add the
  SIEM only, no targets yet, and confirm it ingests something before adding attack surface. On AWS: create
  the CloudTrail trail + log bucket and the read-only SIEM identity, and confirm CloudTrail events show up
  in the SIEM.
- **Phase 2:** first vulnerable target + first attacker tool, one end-to-end scenario, detection rule
  written and confirmed to fire.
- **Phase 3:** expand the scenario catalog, add the Kubernetes- and cloud-specific scenarios, start
  writing them up for the portfolio and mapping them loosely to MITRE ATT&CK / cert objectives.

## Rules of engagement (write this properly before Phase 2)

Once real exploitation is involved, even against intentionally vulnerable targets, put a short explicit
statement in this repo of what's in scope (only pods inside the lab's own namespaces, only over the
NetworkPolicy-allowed paths) and what's never in scope (anything in `argocd`, `cert-manager`, `portfolio`,
`kube-system`, or anything reachable through the public tunnel). For AWS: only resources in your own lab
account, within AWS's published penetration-testing policy (which prohibits things like DoS/flooding tests).
This matters even in a personal homelab —
it's the habit that prevents a scenario from accidentally touching production, and it's the same habit
that matters professionally.

## Open questions for the next planning pass

- SIEM choice: ELK (already written, oversized) vs Wazuh vs Loki-on-Grafana — decide once post-upgrade
  capacity numbers exist.
- Whether the lab needs its own dedicated node (given the resource reality check above) rather than
  sharing `agent-1`/`shubmedia` with the portfolio and monitoring. Leading option: the on-demand AWS lab
  worker described above.
- Whether to upgrade the AWS account to the paid plan before month 6 so unused credits stay usable to
  month 12 (only worth it if the budget alerts show credits left over).
- Exact AWS sign-up date — the 6-month and 12-month deadlines are counted from it; write them here.
- Attacker tooling delivery: a persistent Kali-style pod, or ephemeral Jobs spun up per scenario (cheaper
  at rest, better isolation story since nothing sits around between exercises).
