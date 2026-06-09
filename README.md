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
| `172.22.0.1`         | Host IP on the `provisioning` bridge (netplan, re-asserted each boot) |
| `172.22.0.2`         | Ironic keepalived VIP (lives in the Management object)            |
| `172.22.0.10-100`    | Ironic dnsmasq DHCP pool (Ironic owns DHCP, **not** libvirt)      |
| `172.22.0.1:8000`    | sushy-tools Redfish endpoint                                      |

Each host's BMC address uses the **libvirt domain UUID**, not a MAC/IP, so it stays valid
across clone + reboot:

```
redfish-virtualmedia+https://172.22.0.1:8000/redfish/v1/Systems/<VM-UUID>
```

## Files

| File | Phase | Purpose |
|------|-------|---------|
| `config.env` | both | **Single source of truth** — network, VM UUIDs/MACs, chart coords. Installed to `/etc/k0rdent-bm/config.env`. |
| `bake.sh` | A (once) | Builds everything into the AMI. Idempotent; re-runnable. |
| `phase-b/sushy-tools.service` | B (boot) | Redfish BMC emulator container, `Restart=always`. |
| `phase-b/bootstrap.service` | B (boot) | One-shot, ordered `After=k0scontroller`. |
| `phase-b/bootstrap.sh` | B (boot) | Waits for API/CRDs, patches the Management object, applies the BareMetalHosts. |
| `manifests/bm-templates.yaml` | A | HelmRepository + Provider/Cluster templates. |
| `manifests/management-patch.yaml` | B | Ironic networking merge-patch for the Management object. |
| `manifests/bmh.yaml` | B | Per-host BMC `Secret` + `BareMetalHost` (rendered once per VM). |

All YAML is a template filled by `envsubst` from `config.env`, so config lives in exactly
one place.

## Build (Phase A — run once, then snapshot)

On a **KVM-capable** EC2 instance (`/dev/kvm` present), as root. All charts pull
anonymously from `registry.mirantis.com` — no credentials required:

```bash
sudo ./bake.sh
```

`bake.sh` will:

1. Install packages (libvirt, qemu-kvm, ovmf, k0s, helm, kubectl, docker, jq, …).
2. Configure the `provisioning` bridge (netplan) + libvirt bridge-mode network (no DHCP).
3. Set up the virt-power SSH key and sushy-tools config (conf.py, htpasswd, self-signed cert).
4. Define two UEFI VMs `bmh-0`/`bmh-1` with **fixed** UUID + MAC, autostart off.
5. Bring up k0s, install k0rdent + the bare-metal templates, pre-pull chart/IPA/target artifacts.
6. Install + enable the Phase-B systemd units.

Then verify and snapshot:

```bash
virsh list --all                                  # bmh-0 / bmh-1 -> shut off
systemctl is-enabled k0scontroller sushy-tools bootstrap
sudo poweroff                                     # then create the AMI
```

## Boot (Phase B — every boot, automatic)

systemd-ordered, idempotent:

1. netplan asserts `172.22.0.1`; `libvirtd` up → `provisioning` net autostarts.
2. `sushy-tools.service` starts the Redfish emulator.
3. `k0scontroller.service` brings the cluster back.
4. `bootstrap.service` waits for the API, applies the Management patch + BMC Secrets +
   BareMetalHost CRs.

BareMetalHosts then progress `Registering → Inspecting → Available`:

```bash
export KUBECONFIG=/var/lib/k0s/pki/admin.conf
k0s kubectl -n kcm-system get baremetalhosts -w
journalctl -u bootstrap.service -f               # bootstrap progress
```

## Known caveats / to-confirm

- **RAM (PLAN open-risk #2):** `VM_RAM_MB=6144` × 2 + ~4 GB cluster ≈ 16 GB. On a ~15 GiB
  host this is over budget — `bake.sh` warns but does not block. Lower `VM_RAM_MB` to `4096`
  in `config.env` if the cluster or VMs OOM.
- **Schema guesses (PLAN risks #1, #3)** — verify against the actually-installed charts/CRDs
  before relying on the image:
  - kcm chart name and Management object name (both assumed `kcm`).
  - `spec.providers[].config.ironic.*` sub-keys in `management-patch.yaml`.
  - `bm-templates.yaml` apiVersions (`source.toolkit.fluxcd.io/v1`, `k0rdent.mirantis.com/v1beta1`).
  - `get.mirantis.com` IPA / target image URLs.
- **BMC path is redfish-virtualmedia** (primary); iPXE network boot is the documented fallback
  if the ironic chart can't cleanly disable iPXE.
- Credentials `admin`/`password` and the self-signed sushy-tools cert are **demo-grade only**
  (`disableCertificateVerification: true`). Do not reuse outside a throwaway demo.
