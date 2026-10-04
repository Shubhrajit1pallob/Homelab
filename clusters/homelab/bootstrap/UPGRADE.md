# Control-plane upgrade runbook (`server-1`, 1 → 2 InterServer slices)

Written 2026-10-04 as a plan for later. Nothing here has been run yet. Don't start until the user says the
upgrade is scheduled.

**Roles:** the executor runs `kubectl` from the Mac. The user runs node-level commands over SSH on `server-1` and
pastes the output back.

## Goal

Resize `server-1` from 1 to 2 InterServer slices without losing the cluster. Confirm the control plane, both
agents, ArgoCD and the portfolio come back healthy, and that the swapfile, taint and Tailscale IP are unchanged.

**This covers an in-place resize only.** If InterServer requires a rebuild or reinstall instead, stop: that needs
a separate plan (backing up the datastore and token, then restoring).

## Phase A: before the resize (same day)

**A1. Executor: record the baseline.** Save the outputs to the scratchpad.

```bash
kubectl get nodes -o wide
kubectl describe node server-1 | grep Taints
kubectl get nodes -o custom-columns=NAME:.metadata.name,CPU:.status.capacity.cpu,MEM:.status.capacity.memory
kubectl get pods -A -o wide
kubectl get applications -n argocd
kubectl top nodes
curl -sI https://shubhrajitpallob.dev | head -1
curl -sI https://www.shubhrajitpallob.dev | head -1
```

**A2. User on `server-1`: back up and record.**

```bash
systemctl cat k3s | grep -A10 ExecStart        # install flags (still missing from our notes)
sudo cp /var/lib/rancher/k3s/server/token ~/k3s-token.bak
sudo ls /var/lib/rancher/k3s/server/db/        # state.db (SQLite) or etcd/ ?
# SQLite:  sudo sqlite3 /var/lib/rancher/k3s/server/db/state.db ".backup '/root/state.db.bak'"
# etcd:    sudo k3s etcd-snapshot save --name pre-resize
free -m; swapon --show; grep swap /etc/fstab
sysctl vm.swappiness
tailscale ip -4
df -h /; lsblk
```

Copy the token and the datastore backup **off the server** (scp them to the Mac). Never put them in this repo:
it is public.

**Stop if:** the backup fails, or `ExecStart` pins an IP that isn't the Tailscale `100.x` one.

## Phase B: the resize (user)

Resize in the InterServer panel. Expect a reboot. The Kubernetes API will be down for a few minutes and ArgoCD
pauses. The portfolio pods on `agent-1` keep running, but public traffic will likely drop for those minutes: the
only Traefik replica runs on `server-1`, and every tunnel request goes through it.

## Phase C: after the resize

**C1. User on `server-1`:**

```bash
nproc; free -m                  # expect 1 core (2 slices is still 1 core), ~3.8 GiB
swapon --show                   # 2 GiB swapfile still active?
sysctl vm.swappiness            # expect 10
tailscale ip -4                 # must match A2
df -h /; lsblk                  # did the disk grow? (report only; don't run growpart/resize2fs yet)
systemctl status k3s --no-pager | head -5
```

**C2. Executor:** rerun everything from A1 and compare with the baseline. Checks:

- All 3 nodes are `Ready`, and `server-1` shows the new memory capacity (~4 GiB; CPU stays at 1).
- `server-1` still has its control-plane `NoSchedule` taint.
- Every ArgoCD Application is `Synced` / `Healthy`, and the `portfolio` pods are 2/2 on `agent-1`.
- The apex and `www` both return HTTP 200.
- No pods are stuck in `CrashLoopBackOff` or `Pending`, and restart counts look normal.
- `kubectl top nodes` shows `server-1` well below its old ~64% memory use.

## Do not

- Commit, push, or edit any Git file. The user does all Git work.
- Re-enable `cert-manager` or anything else in `parked/`. That's a separate step.
- Change K3s flags, taints or labels, or drain or cordon any node.
- Grow the filesystem or recreate swap without the user's go-ahead. Report what's needed instead.

## Report back to the planner

1. A before/after table: nodes, capacity, memory %, taint, swap, Tailscale IP, Application status, portfolio HTTP
   codes.
2. The `ExecStart` flags, with any secrets redacted. Note whether the datastore is SQLite or etcd.
3. Anything that changed unexpectedly, as raw output.
4. Whether the disk grew and whether the filesystem needs extending.

## If something goes wrong

- **Agents show `NotReady` after 5 minutes:** check `tailscale status` on all three nodes. A changed IP is the
  most likely cause.
- **K3s won't start:** `journalctl -u k3s -n 100`, and report the output before doing anything else.
- **Worst case:** restore from the A2 backup. That gets its own runbook. Don't improvise.

## What comes next

1. Re-enable `cert-manager` + `cert-manager-config` (ArgoCD will adopt the hand-installed Helm release, so check
   the diff before syncing), then `argocd-config`.
2. Add the media node: a 2-slice InterServer storage VPS in Secaucus, NJ, running Jellyfin, Tailscale-only.
