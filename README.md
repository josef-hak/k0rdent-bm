# k0rdent bare-metal demo AMI

A single Ubuntu EC2 VM that runs a **k0rdent Enterprise** management cluster with the
bare-metal provider (Metal3 / Ironic / CAPM3), plus **two pre-created libvirt VMs** acting
as fake bare-metal hosts via [sushy-tools](https://github.com/openstack/sushy-tools) (Redfish).

The image is built once and snapshotted into an AMI. It must come up working both when
**cloned from the snapshot** and **after a reboot** — for testing/demoing k0rdent + the
bare-metal plugin. See [`k0rdent-bm-ami-PLAN.md`](k0rdent-bm-ami-PLAN.md) for the full design.

## How it stays snapshot- and reboot-safe

The single thing everything depends on is the static, isolated provisioning network
`172.22.0.0/24`. The cloud `eth0` IP/MAC/hostname (which change on clone/reboot) are
referenced **nowhere**.

| Address              | Role                                                              |
|----------------------|-------------------------------------------------------------------|
| `172.22.0.1`         | Host IP on the `lab` bridge (netplan, re-asserted each boot) |
| `172.22.0.2`         | Ironic keepalived VIP (lives in the Management object)            |
| `172.22.0.10-100`    | Ironic dnsmasq DHCP pool (Ironic owns DHCP, **not** libvirt)      |
| `172.22.0.1:8000`    | sushy-tools Redfish endpoint                                      |

Each host's BMC address uses the **libvirt domain UUID**, not a MAC/IP, so it stays valid
across clone + reboot:

```
redfish-virtualmedia+https://172.22.0.1:8000/redfish/v1/Systems/<VM-UUID>
```

## Files

| File | When | Purpose |
|------|------|---------|
| `config.env` | both | **Single source of truth** — network, VM UUIDs/MACs, chart coords. Installed to `/etc/k0rdent-bm/config.env`. |
| `install.sh` | install (once) | Builds everything into the AMI. Idempotent; re-runnable. Run whole, or step by step via `make` (`make help`). |
| `helm/kcm.yaml` | install | k0rdent Enterprise (kcm) values — enables the UI with basic auth. |
| `helm/traefik.yaml` | install | Traefik ingress values — DaemonSet on host ports 80/443. |
| `runtime/sushy-tools.service` | runtime (boot) | Redfish BMC emulator container, `Restart=always`. |
| `runtime/lab-nat.service` | runtime (boot) | Brings the `lab` bridge up (dummy `lab-up` carrier) + NAT/forwarding for it (after docker). |
| `runtime/k0rdent-bm-setup.service` | runtime (boot) | One-shot, ordered `After=k0scontroller`. |
| `runtime/k0rdent-bm-setup.sh` | runtime (boot) | Waits for API/CRDs, patches the Management object, applies the BareMetalHosts. |
| `manifests/bm-templates.yaml` | install | HelmRepository + Provider/Cluster templates. |
| `manifests/management-patch.yaml` | runtime | Ironic networking merge-patch for the Management object. |
| `manifests/bmh.yaml` | runtime | Per-host BMC `Secret` + `BareMetalHost` (rendered once per VM). |

All YAML is a template filled by `envsubst` from `config.env`, so config lives in exactly
one place.

## Build (install.sh — run once, then snapshot)

On a **KVM-capable** EC2 instance (`/dev/kvm` present), as root. All charts pull
anonymously from `registry.mirantis.com` — no credentials required:

```bash
sudo ./install.sh                 # whole build; or step by step: make help
```

`install.sh` will:

1. Install packages (libvirt, qemu-kvm, ovmf, k0s, helm, kubectl, docker, jq, …).
2. Configure the `lab` bridge (netplan) + libvirt bridge-mode network (no DHCP).
3. Set up the virt-power SSH key and sushy-tools config (conf.py, htpasswd, self-signed cert).
4. Define two UEFI VMs `bmh-0`/`bmh-1` with **fixed** UUID + MAC, autostart off.
5. Bring up k0s (export kubeconfig to `~/.kube/config`), install Traefik ingress, k0rdent
   Enterprise (kcm), and the bare-metal provider templates. (The IPA ramdisk + target OS image
   are fetched at runtime by the Ironic chart — not pre-pulled here.)
6. Install + enable the runtime systemd units.

Then verify and snapshot:

```bash
virsh list --all                                  # bmh-0 / bmh-1 -> shut off
systemctl is-enabled k0scontroller sushy-tools lab-nat k0rdent-bm-setup
sudo poweroff                                     # then create the AMI
```

## Boot / runtime (every boot, automatic)

systemd-ordered, idempotent:

1. netplan asserts `172.22.0.1`; `libvirtd` up → `lab` net autostarts.
2. `sushy-tools.service` starts the Redfish emulator.
3. `lab-nat.service` brings the `lab` bridge up via an always-up dummy slave (`lab-up`) — so
   keepalived can assign the VIP even before any VM boots — and applies NAT/forwarding (after docker).
4. `k0scontroller.service` brings the cluster back.
5. `k0rdent-bm-setup.service` waits for the API, applies the Management patch + BMC Secrets +
   BareMetalHost CRs.

BareMetalHosts then progress `Registering → Inspecting → Available`:

```bash
export KUBECONFIG=/var/lib/k0s/pki/admin.conf
k0s kubectl -n kcm-system get baremetalhosts -w
journalctl -u k0rdent-bm-setup.service -f        # setup progress
```

## Known caveats / to-confirm

- **RAM:** `VM_RAM_MB` defaults to `4096` (2×4 GB + ~4 GB cluster ≈ 12 GB, fits a ~15 GiB host).
  `install.sh` warns if host RAM looks short but does not block; lower it if the cluster or VMs OOM.
- **Images are not configured/pre-pulled here:** the `ironic` subchart ships correct
  `images_ipa`/`images_target` URLs (`get.mirantis.com/k0rdent-enterprise/bare-metal/…`) and serves
  them from its in-cluster httpd. `management-patch.yaml` only overrides Ironic **networking**
  (`interface`/`ipAddress`/`dhcp`), verified against `charts/ironic` 0.5.0 values.
- **`lab` bridge needs a carrier:** with no VMs running the bridge is DOWN, so keepalived won't
  assign the VIP and Ironic hangs waiting for it. `lab-nat.service` fixes this with the `lab-up`
  dummy slave (see boot step 3).
- **BMC path is `redfish-virtualmedia`** (primary); plain `redfish` (iPXE network boot) is the
  documented fallback.
- Credentials `admin`/`password` and the self-signed sushy-tools cert are **demo-grade only**
  (`disableCertificateVerification: true`). Do not reuse outside a throwaway demo.
