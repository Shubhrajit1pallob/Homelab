# SSH hardening runbook (`server-1`, then `agent-1`)

Written 2026-10-04 as a plan for later. Nothing here has been run yet.

**Goal:** no root logins over SSH, no passwords, and logins only from the tailnet, without locking yourself out.
Every step is run by the user (the executor has no SSH access).

**Why:** `server-1` currently accepts root login with a password on its public IP, which automated attacks probe
around the clock.

**Placeholders** (this repo is public, so keep real values out of it):

- `<ts-ip>`: the node's Tailscale IP (`tailscale ip -4` on the node)
- `<public-ip>`: the node's public IP
- `<admin-user>`: the new admin username you pick

## Step 0: make sure you have a way back in

Open the **InterServer control panel → the VPS → VNC/console** and check you can log in there as root with your
password. That console is the way back if SSH breaks. Keep it open in a browser tab for the whole procedure.

## Step 1: an SSH key on the Mac

```bash
ls ~/.ssh/id_ed25519.pub || ssh-keygen -t ed25519 -C "shawn47-mac"
```

Give the key a passphrase; macOS Keychain remembers it.

## Step 2: a normal admin user on the node

Still logged in as root:

```bash
adduser <admin-user>            # set a strong password; sudo needs it
usermod -aG sudo <admin-user>
```

## Step 3: copy the key, then test in a NEW terminal

On the Mac:

```bash
ssh-copy-id <admin-user>@<ts-ip>
```

In a **second terminal**, leaving the root session open:

```bash
ssh <admin-user>@<ts-ip>        # should log in with the key, no server password
sudo -v                         # should accept <admin-user>'s password
```

**Don't continue unless both work.**

## Step 4: turn off passwords and root logins

On the node, as root:

```bash
cat >/etc/ssh/sshd_config.d/10-hardening.conf <<'EOF'
PermitRootLogin no
PasswordAuthentication no
KbdInteractiveAuthentication no
PubkeyAuthentication yes
MaxAuthTries 3
AllowUsers <admin-user>@100.64.0.0/10
EOF
sshd -t && sshd -T | grep -Ei 'permitrootlogin|passwordauthentication|kbdinteractive|allowusers'
```

- **The `10-` in the file name matters.** Ubuntu ships `50-cloud-init.conf`, which often turns passwords back on.
  When a setting appears twice, sshd uses the first value it reads, and the files are read in name order, so
  `10-` wins. `sshd -T` shows what's actually in effect: it must say `permitrootlogin no` and
  `passwordauthentication no`.
- **`AllowUsers <admin-user>@100.64.0.0/10`** allows only that user, and only from a Tailscale address. Logins
  from the public internet are refused even with a valid key. This needs no firewall changes, which matters: a
  host firewall rule could easily break K3s networking (API, kubelet, flannel, ServiceLB ports).

Then:

```bash
systemctl reload ssh
```

## Step 5: test, still keeping the root session open

From the Mac, in new terminals:

```bash
ssh <admin-user>@<ts-ip>                                # should work
ssh -o PubkeyAuthentication=no <admin-user>@<ts-ip>     # should fail: "Permission denied (publickey)"
ssh root@<public-ip>                                    # should be refused
```

If all three behave as described, close the root session.

## Step 6: a convenience shortcut

In `~/.ssh/config` on the Mac:

```
Host server-1
  HostName <ts-ip>
  User <admin-user>
```

Then `ssh server-1` just works.

## Notes

- **If you get locked out:** log in through the InterServer console (Step 0) and delete
  `/etc/ssh/sshd_config.d/10-hardening.conf`, then `systemctl reload ssh`.
- **If Tailscale is down on the node,** SSH is unreachable too. The console is the fallback.
- **`agent-1`:** if it's also a VPS with a public IP, repeat Steps 0-6 there after `server-1` checks out.
  `shubmedia` is a laptop at home behind the router, so it's lower priority.
- The root password is still needed for the console, so keep it, and don't reuse it anywhere.
- Optional later: Tailscale SSH (`tailscale up --ssh`) can replace key management entirely.
