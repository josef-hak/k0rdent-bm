# Makefile - run the k0rdent bare-metal demo build (bake.sh) one step at a time.
#
# Each "build step" target sources bake.sh and runs exactly one of its
# functions, so steps are individually re-runnable and idempotent (each guards
# against already-done state). `make all` runs the whole bake in one shot
# (identical to `sudo ./bake.sh`).
#
# All build steps need root, so the recipes invoke sudo themselves -> just run
# `make <target>` (you'll be prompted for a password once per step).
#
#   make help            # list targets
#   make check           # step 1
#   ...
#   make units            # step 9
#   make all             # everything (= sudo ./bake.sh)
#   make start           # Phase B: start services now (instead of rebooting)
#   make status          # show current state of everything

SHELL := /bin/bash
BAKE  := $(CURDIR)/bake.sh
# Source bake.sh (defines functions; main() is guarded so it won't run) then
# call one function as root.
RUN    = sudo bash -c 'source $(BAKE) && $(1)'

.PHONY: help all \
        check packages config net virtpower sushy vms k0s ingress kcm bm units \
        start status watch-bmh clean

# ----------------------------------------------------------------------------
help:
	@echo "k0rdent bare-metal demo - build steps (run in order, or 'make all'):"
	@echo "  1. make check       - check root / KVM / RAM"
	@echo "  2. make packages    - apt + docker + helm + kubectl + k0s"
	@echo "  3. make config      - install config.env to /etc/k0rdent-bm"
	@echo "  4. make net         - provisioning bridge + libvirt network"
	@echo "  5. make virtpower   - virt-power SSH key"
	@echo "  6. make sushy       - sushy-tools config + image pull"
	@echo "  7. make vms         - define bmh-0 / bmh-1"
	@echo "  8. make k0s         - k0s single-node controller"
	@echo "  9. make ingress     - Traefik ingress (expose k0rdent UI on 80/443)"
	@echo " 10. make kcm         - k0rdent Enterprise management cluster"
	@echo " 11. make bm          - BM provider templates + artifact pre-pull"
	@echo " 12. make units       - install + enable Phase-B systemd units"
	@echo "     make all         - all of the above (= sudo ./bake.sh)"
	@echo ""
	@echo "Operate / verify:"
	@echo "     make start       - Phase B now: start k0s + sushy + bootstrap"
	@echo "     make status      - show state of bridge/VMs/services/cluster"
	@echo "     make watch-bmh   - watch BareMetalHosts reconcile"

# ---- full build ------------------------------------------------------------
all:
	sudo $(BAKE)

# ---- build steps (1:1 with bake.sh functions) ------------------------------
check:     ;	$(call RUN,preflight)
packages:  ;	$(call RUN,install_packages)
config:    ;	$(call RUN,install_config)
net:       ;	$(call RUN,setup_provisioning_net)
virtpower: ;	$(call RUN,setup_virtpower_key)
sushy:     ;	$(call RUN,setup_sushy)
vms:       ;	$(call RUN,define_vms)
k0s:       ;	$(call RUN,install_k0s)
ingress:   ;	$(call RUN,install_ingress)
kcm:       ;	$(call RUN,install_kcm)
bm:        ;	$(call RUN,install_bm)
units:     ;	$(call RUN,install_phase_b)

# ---- Phase B / operate -----------------------------------------------------
# Start the boot-time services now instead of rebooting. k0scontroller comes
# up, sushy-tools starts, then bootstrap.service patches Management + applies
# the BareMetalHosts.
start:
	sudo systemctl start k0scontroller sushy-tools.service lab-nat.service
	sudo systemctl start bootstrap.service

# ---- verify / inspect ------------------------------------------------------
status:
	@echo "=== KVM ==="          ; ls -l /dev/kvm 2>&1 || true
	@echo "=== RAM ==="          ; free -h | awk '/Mem/{print "total="$$2" used="$$3" free="$$4}'
	@echo "=== config ==="       ; ls -l /etc/k0rdent-bm/ 2>&1 || true
	@echo "=== bridge ==="       ; ip -br addr show "$$(. $(CURDIR)/config.env; echo $$PROV_BRIDGE)" 2>&1 || true
	@echo "=== libvirt net ==="  ; sudo virsh net-list --all 2>&1 || true
	@echo "=== VMs ==="          ; sudo virsh list --all 2>&1 || true
	@echo "=== services ===" ; for s in k0scontroller sushy-tools.service lab-nat.service bootstrap.service; do \
	  printf '  %-22s enabled=%-10s active=%s\n' "$$s" \
	    "$$(systemctl is-enabled $$s 2>/dev/null)" \
	    "$$(systemctl is-active  $$s 2>/dev/null)"; \
	done
	@echo "=== sushy container ===" ; sudo docker ps --filter name=sushy-tools --format '{{.Names}} {{.Status}}' 2>&1 || true
	@echo "=== BareMetalHosts ===" ; sudo k0s kubectl -n kcm-system get baremetalhosts 2>&1 || echo "(cluster not up)"

watch-bmh:
	sudo KUBECONFIG=/var/lib/k0s/pki/admin.conf k0s kubectl -n kcm-system get baremetalhosts -w

# Remove the throwaway helper from the earlier sourcing approach (if present).
clean:
	rm -f $(CURDIR)/.bake-fns.sh
