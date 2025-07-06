#!/usr/bin/env bash
#
# Description: This script configures the Linux kernel for Kubernetes.
#
set -euo pipefail

echo "[TASK 1] Load required kernel modules"
sudo modprobe overlay
sudo modprobe br_netfilter

cat <<EOF | sudo tee /etc/modules-load.d/k8s.conf
overlay
br_netfilter
EOF

echo "[TASK 2] Set required networking parameters"
cat <<EOF | sudo tee /etc/sysctl.d/k8s.conf
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
EOF

echo "[TASK 3] Apply sysctl params without reboot"
sudo sysctl --system
