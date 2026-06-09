# Handoff: single-VM k0rdent bare-metal demo AMI

Resume context for continuing on the running EC2 instance (KVM-capable). Built using
metal3-dev-env as the reference for the libvirt + sushy-tools "fake bare metal" trick.

## Goal
A single Ubuntu EC2 VM that runs a k0rdent Enterprise management cluster with the bare-metal
provider (Metal3 / Ironic / CAPM3), plus TWO pre-created libvirt VMs acting as fake bare-metal
hosts via sushy-tools (Redfish). Must work when the VM is cloned from a snapshot/AMI AND after
reboot. For testing/demoing k0rdent + bare-metal plugin.

## Locked decisions
- Platform: AWS EC2, KVM confirmed available (/dev/kvm present, 16 vCPU) -> LIBVIRT_DOMAIN_TYPE=kvm.
- Mgmt cluster runtime: k0s single-node (systemd, reboot/snapshot-safe), NOT kind.
- BMC path: redfish-virtualmedia via sushy-tools (PRIMARY); iPXE network boot is FALLBACK.
- k0rdent BM charts: oci://registry.mirantis.com/k0rdent-bm/charts/ (CAPM3 provider 0.5.0).

## Design anchor (snapshot/reboot safety)
Static isolated provisioning network 172.22.0.0/24 is the only thing anything depends on.
The cloud eth0 IP/MAC/hostname (changes on clone/reboot) is referenced NOWHERE.
- 172.22.0.1   host IP on `provisioning` bridge (netplan, re-asserted each boot)
- 172.22.0.2   Ironic keepalived VIP (in Management object)
- 172.22.0.10-100  Ironic dnsmasq DHCP pool
- 172.22.0.1:8000  sushy-tools Redfish
- BMC address per host: redfish-virtualmedia+https://172.22.0.1:8000/redfish/v1/Systems/<VM-UUID>
  (uses VM UUID, NOT MAC/IP -> stable across clone/reboot)
- k0s API SANs pinned to 127.0.0.1 + 172.22.0.1; kubeconfig server https://localhost:6443.

## Component stack
- k0s single-node (`k0s install controller --single`) -> k0scontroller systemd unit; state in /var/lib/k0s.
- k0rdent Enterprise + BM charts (baremetal-operator, cluster-api-provider-metal3 0.5.0, ironic).
- Ironic in-cluster, hostNetwork, bound to `provisioning` iface; provides dnsmasq DHCP (needed even
  for virtual media so the IPA ramdisk gets an IP) + httpd + keepalived VIP.
- sushy-tools container (--net host, --restart=always), Redfish for libvirt VMs over
  qemu+ssh://root@127.0.0.1/system (reuse metal3-dev-env virt-power SSH-key pattern).
- libvirt/KVM: isolated `provisioning` net (static, autostart, DHCP OFF - Ironic owns DHCP) + 2 UEFI VMs.

## Two-phase build
Phase A - bake into AMI (run once, then snapshot):
  1. apt: libvirt, qemu-kvm, ovmf, k0s, helm, kubectl, docker, jq.
  2. Create isolated `provisioning` libvirt net (static 172.22.0.0/24, autostart, no DHCP) + netplan host 172.22.0.1.
  3. Create 2 UEFI VMs bmh-0/bmh-1: OVMF, ~6-8GB RAM, ~25GB disk, NIC on provisioning, FIXED MAC+UUID,
     console=ttyS0, autostart=off.
  4. virt-power SSH key; sushy-tools conf.py + htpasswd (admin/password) + self-signed cert; pre-pull image.
  5. Install k0s + k0rdent; create BM HelmRepository/ProviderTemplate/ClusterTemplate; pre-pull
     chart + IPA + target-image artifacts.
  6. Install Phase-B systemd units, enable, power off, snapshot/AMI.
Phase B - every boot (idempotent, systemd-ordered):
  1. netplan asserts 172.22.0.1; libvirtd up -> provisioning net autostarts.
  2. sushy-tools container (--restart=always).
  3. k0scontroller.service -> pods return.
  4. bootstrap.service (oneshot, After=k0scontroller): wait for API, kubectl apply Management patch
     (Ironic networking) + BMH Secrets + BareMetalHost CRs. BMHs go Registering->Inspecting->Available.

## k0rdent objects (from Mirantis docs)
- HelmRepository oot-capm3-repo -> oci://registry.mirantis.com/k0rdent-bm/charts/ (ns kcm-system).
- ProviderTemplate cluster-api-provider-metal3-0-5-0 (chart cluster-api-provider-metal3 v0.5.0).
- ClusterTemplate capm3-standalone-cp-0-5-0 (chart capm3-standalone-cp v0.5.0).
- Edit Management object: provider cluster-api-provider-metal3 with config global.ironic.enabled=true
  and ironic.networking.dhcp{rangeBegin/End=172.22.0.10/100, netmask 255.255.255.0,
  options[router 172.22.0.1]}, interface=provisioning, ipAddress=172.22.0.2 (VIP). images_ipa /
  images_target from get.mirantis.com.
- Per host: Secret (BMC creds admin/password) + BareMetalHost (bmc.address redfish-virtualmedia+...UUID,
  disableCertificateVerification true, bootMACAddress, bootMode UEFI).

## NOT yet done
Scripts not written (user chose "plan only"). Next deliverables: bake.sh, Phase-B systemd units +
bootstrap.sh, management-patch.yaml, bmh.yaml templates.

## Open risks
1. Does k0rdent ironic chart cleanly support virtual-media / disabling iPXE? (else use iPXE fallback) - test first.
2. Confirm instance RAM fits k0s + k0rdent + 2 VMs.
3. registry.mirantis.com pull creds / k0rdent Enterprise license needed at bake time.
