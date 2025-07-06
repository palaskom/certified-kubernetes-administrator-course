#!/usr/bin/env bash
#
# Description: This script deploys or destroys a Kubernetes cluster using Multipass VMs.
# It takes a configuration file as an argument to define the cluster topology for creation.
# For destruction, it requires the cluster name.
#

set -euo pipefail

# Get the directory where this script is located
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# --- Color Codes ---
RED="\033[1;31m"
YELLOW="\033[1;33m"
GREEN="\033[1;32m"
BLUE="\033[1;34m"
NC="\033[0m"

# --- Script Functions ---

# Function to print error messages and exit
function die() {
    echo -e "${RED}ERROR: $1${NC}"
    exit 1
}

# Function to check for required commands
function check_dependencies() {
    echo -e "${BLUE}[INFO] Checking for dependencies...${NC}"
    command -v multipass >/dev/null 2>&1 || die "'multipass' command not found. Please install it."
    command -v jq >/dev/null 2>&1 || die "'jq' command not found. Please install it."
    command -v mapfile >/dev/null 2>&1 || die "'mapfile' command not found. Please install it."
    command -v tailscale >/dev/null 2>&1 || die "'tailscale' command not found. Please install it."
}

function authenticate_multipass() {
    echo -e "\n${BLUE}[INFO] Authenticating with Multipass service...${NC}"
    if ! multipass authenticate '*'; then
        die "Multipass authentication failed. Please run 'multipass authenticate' manually."
    fi
    echo -e "${GREEN}Multipass client authenticated successfully.${NC}"
}

# Function to log messages
log() {
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] $1"
}

# --- Network Setup ---
function setup_bridge_network() {
    echo -e "\n${BLUE}[INFO] Setting up Multipass bridge network...${NC}"
    multipass get local.bridged-network
    # Check if the primary network is already set
    if multipass get local.bridged-network | grep -q "bridged"; then
        echo -e "${GREEN}Bridge network is already configured.${NC}"
        return
    fi

    local interface=""
    if [ -n "${BRIDGE_INTERFACE-}" ]; then
        interface=$BRIDGE_INTERFACE
        echo -e "${GREEN}Using bridge interface from config: ${interface}${NC}"
    else
        # Auto-detect the default interface on Linux
        interface=$(ip route | grep '^default' | awk '{print $5}' | head -n1)
        if [ -z "$interface" ]; then
            die "Could not auto-detect a default network interface for bridging. Please set BRIDGE_INTERFACE in your config file."
        else
            echo -e "${GREEN}Detected default interface: ${interface}. Configuring bridge.${NC}"
        fi
    fi
    multipass set local.bridged-network="$interface"
}

# --- VM Management ---

# Function to check if any VMs for the cluster already exist
function check_existing_vms() {
    echo -e "\n${BLUE}[INFO] Checking for existing VMs for cluster '${CLUSTER_NAME}'...${NC}"
    existing_vms=$(multipass list --format json | jq -r ".list[].name | select(startswith(\"${CLUSTER_NAME}-\"))")
    echo "marios"
    if [ -n "$existing_vms" ]; then
        echo -e "${YELLOW}WARNING: Found existing VMs for this cluster:${NC}"
        echo "$existing_vms"
        read -p "Delete these VMs and start fresh? (y/n) " -n 1 -r
        echo
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            echo -e "${BLUE}Deleting existing VMs...${NC}"
            echo "$existing_vms" | xargs -L1 multipass delete
            multipass purge
        else
            die "Aborting deployment due to existing VMs."
        fi
    fi
}

# Function to launch all cluster VMs
function launch_vms() {
    echo -e "\n${BLUE}[INFO] Launching cluster VMs...${NC}"

    # Launch Control Plane Nodes
    echo -e "${BLUE}Launching ${CONTROL_PLANE_COUNT} control plane node(s)...${NC}"
    for i in $(seq 1 $CONTROL_PLANE_COUNT); do
        name="${CLUSTER_NAME}-controlplane-${i}"
        echo "Launching ${name}..."
        multipass launch --name "$name" \
            --cpus "$CONTROL_PLANE_CPU" \
            --memory "$CONTROL_PLANE_MEM" \
            --disk "$CONTROL_PLANE_DISK" \
            --bridged \
            --cloud-init "${SCRIPT_DIR}/configs/control-plane-init.yaml"

        echo "Adding ${name} to VPN..."
        multipass transfer ~/marios/.tailscale-authkey $name:/tmp/.tailscale-authkey # TODO: Renew - Expires on Oct 4, 2025
        multipass exec $name -- \
            bash -c "curl -fsSL https://tailscale.com/install.sh | sh && sudo tailscale up --authkey \$(cat /tmp/.tailscale-authkey)"
        multipass exec $name -- rm /tmp/.tailscale-authkey
    done
# ,mode=manual \

    # Launch Worker Nodes
    echo -e "\n${BLUE}Launching ${WORKER_COUNT} worker node(s)...${NC}"
    for i in $(seq 1 $WORKER_COUNT); do
        name="${CLUSTER_NAME}-worker-${i}"
        echo "Launching ${name}..."
        multipass launch --name "$name" \
            --cpus "$WORKER_CPU" \
            --memory "$WORKER_MEM" \
            --disk "$WORKER_DISK" \
            --bridged \
            --cloud-init "${SCRIPT_DIR}/configs/worker-init.yaml"

        echo "Adding ${name} to VPN..."
        multipass transfer ~/marios/.tailscale-authkey $name:/tmp/.tailscale-authkey
        multipass exec $name -- \
            bash -c "curl -fsSL https://tailscale.com/install.sh | sh && sudo tailscale up --authkey \$(cat /tmp/.tailscale-authkey)"
        multipass exec $name -- rm /tmp/.tailscale-authkey
    done


}
# ,mode=manual \

# --- Kubernetes Bootstrapping ---

function bootstrap_cluster() {
    echo -e "\n${BLUE}[INFO] Bootstrapping Kubernetes cluster...${NC}"

    local cp1_name="${CLUSTER_NAME}-controlplane-1"

    # Correctly determine home directory whether running with sudo or not
    local user_home
    if [ -n "${SUDO_USER-}" ]; then
        user_home=$(getent passwd "$SUDO_USER" | cut -d: -f6)
    else
        user_home=$HOME
    fi
    local kubeconfig_path="${user_home}/.kube/config_${CLUSTER_NAME}"
    local kubeconfig_dir=$(dirname "$kubeconfig_path")

    # Get the IP of the primary control plane
    echo -e "${BLUE}[INFO] Getting IP of control plane node: ${cp1_name}${NC}"
    local cp1_ip=$(multipass info "$cp1_name" --format json | jq -r ".info[\"$cp1_name\"].ipv4[0]")
    [ -z "$cp1_ip" ] && die "Could not retrieve IP address for ${cp1_name}."
    echo -e "${GREEN}Control plane IP: ${cp1_ip}${NC}"

    # # Ensure kernel parameters are properly set before kubeadm init
    # echo -e "\n${BLUE}[INFO] Verifying and setting kernel parameters on ${cp1_name}...${NC}"
    # multipass exec "$cp1_name" -- sudo sysctl net.ipv4.ip_forward=1
    # multipass exec "$cp1_name" -- sudo sysctl net.bridge.bridge-nf-call-iptables=1
    # multipass exec "$cp1_name" -- sudo sysctl net.bridge.bridge-nf-call-ip6tables=1

    echo -e "${BLUE}[INFO] Getting the VIP of control plane node: ${cp1_name}${NC}"
    local cp1_vip=$(multipass exec "$cp1_name" -- tailscale ip -4)
    [ -z "$cp1_vip" ] && die "Could not retrieve VIP address for ${cp1_name}."
    echo -e "${GREEN}Control plane IP: ${cp1_vip}${NC}"
    # Initialize the control plane
    echo -e "\n${BLUE}[INFO] Initializing Kubernetes control plane on ${cp1_name}...${NC}"
    # Using flannel as CNI, default CIDR is 10.244.0.0/16
    multipass exec "$cp1_name" -- sudo kubeadm init \
        --node-name="$cp1_name" \
        --pod-network-cidr=10.244.0.0/16 \
        --apiserver-advertise-address="$cp1_ip" \
        --apiserver-cert-extra-sans="$cp1_vip" \
        --upload-certs

    # Get kubeconfig from the control plane
    echo -e "\n${BLUE}[INFO] Fetching kubeconfig and saving to ${kubeconfig_path}${NC}"
    echo -e "${BLUE}[DEBUG] Current user: $(whoami)${NC}"
    echo -e "${BLUE}[DEBUG] Home directory: ${user_home}${NC}"
    echo -e "${BLUE}[DEBUG] Kubeconfig directory: ${kubeconfig_dir}${NC}"
    echo -e "${BLUE}[DEBUG] Creating directory: ${kubeconfig_dir}${NC}"

    # Ensure the parent directory exists and has correct permissions
    if [ ! -d "${user_home}" ]; then
        echo -e "${RED}[ERROR] Home directory ${user_home} does not exist${NC}"
        exit 1
    fi

    # Create the .kube directory with proper permissions
    mkdir -p "$kubeconfig_dir" || {
        echo -e "${RED}[ERROR] Failed to create directory ${kubeconfig_dir}${NC}"
        echo -e "${RED}[ERROR] Trying to create with sudo...${NC}"
        sudo mkdir -p "$kubeconfig_dir"
        sudo chown "$(whoami):$(whoami)" "$kubeconfig_dir"
    }

    echo -e "${BLUE}[DEBUG] Copying kubeconfig from VM to host${NC}"
    multipass exec "$cp1_name" -- sudo cat /etc/kubernetes/admin.conf > "$kubeconfig_path"

    # Set ownership of the kubeconfig file to the original user
    if [ -n "${SUDO_USER-}" ]; then
        chown "$SUDO_USER:$SUDO_USER" -R "$kubeconfig_dir"
    fi
    chmod 600 "$kubeconfig_path"

    echo -e "${GREEN}Kubeconfig saved. To use it, run:${NC}"
    echo -e "  ${YELLOW}export KUBECONFIG=${kubeconfig_path}${NC}"

    # Install Flannel CNI
    echo -e "\n${BLUE}[INFO] Installing Flannel CNI...${NC}"
    multipass exec "$cp1_name" -- sudo kubectl --kubeconfig /etc/kubernetes/admin.conf apply -f https://raw.githubusercontent.com/flannel-io/flannel/master/Documentation/kube-flannel.yml

    # Get the join command
    echo -e "\n${BLUE}[INFO] Generating worker join command...${NC}"
    local join_command=$(multipass exec "$cp1_name" -- sudo kubeadm token create --print-join-command)

    # Join worker nodes to the cluster
    if [ "$WORKER_COUNT" -gt 0 ]; then
        echo -e "\n${BLUE}[INFO] Joining ${WORKER_COUNT} worker node(s) to the cluster...${NC}"
        for i in $(seq 1 $WORKER_COUNT); do
            local worker_name="${CLUSTER_NAME}-worker-${i}"
            echo "Joining ${worker_name}..."
            multipass exec "$worker_name" -- sudo $join_command --node-name="$worker_name"
        done
    fi
}

# Function to destroy the cluster VMs
destroy_cluster() {
    log "Destroying Kubernetes cluster: ${CLUSTER_NAME}..."

    # # Find all VMs associated with the cluster
    # mapfile -t vms_to_delete < <(multipass list --format csv | grep "${CLUSTER_NAME}" | cut -d, -f1)

    vms_to_delete=($(multipass list --format json | jq -r '.list[].name'| grep "${CLUSTER_NAME}-"))

    if [ ${#vms_to_delete[@]} -eq 0 ]; then
        log "No VMs found for cluster '${CLUSTER_NAME}'."
        return
    fi

    for vm_name in "${vms_to_delete[@]}"; do
        log "Deleting VM: ${vm_name}..."
        multipass delete "${vm_name}" --purge
    done

    log "Cluster '${CLUSTER_NAME}' destroyed."
}

# --- Main Script ---

# Check if a configuration file was provided
if [ -z "${1-}" ]; then
    die "Usage: $0 <create|destroy> [config_file]"
fi

ACTION=$1
shift

# --- Action: create ---
if [[ "$ACTION" == "create" ]]; then
    if [[ "$#" -ne 1 ]]; then
        echo "Usage: $0 create <config_file>"
        exit 1
    fi
    CONFIG_FILE=$1
    # Check if the config file exists
    if [ ! -f "$CONFIG_FILE" ]; then
        die "Configuration file not found at: $CONFIG_FILE"
    fi

    # Load configuration from the file
    echo -e "${BLUE}[INFO] Loading configuration from $CONFIG_FILE...${NC}"
    source $CONFIG_FILE

    # Validate configuration
    [ -z "${CLUSTER_NAME-}" ] && die "CONFIG_FILE must define CLUSTER_NAME."
    [ -z "${CONTROL_PLANE_COUNT-}" ] && die "CONFIG_FILE must define CONTROL_PLANE_COUNT."
    [ -z "${WORKER_COUNT-}" ] && die "CONFIG_FILE must define WORKER_COUNT."


    echo -e "${GREEN}Configuration loaded successfully:${NC}"
    echo -e "  Cluster Name: ${YELLOW}${CLUSTER_NAME}${NC}"
    echo -e "  Control Plane Nodes: ${YELLOW}${CONTROL_PLANE_COUNT}${NC}"
    echo -e "  Worker Nodes: ${YELLOW}${WORKER_COUNT}${NC}"

    # Check dependencies
    check_dependencies

    # multipass set local.bridged-network=mpqemubr0

    # # Authenticate with Multipass
    # authenticate_multipass

    # # Setup network
    # setup_bridge_network
    # multipass set local.bridged-network=enp8s0

    # Check for existing VMs
    # check_existing_vms

    # Launch VMs
    launch_vms

    # Bootstrap Kubernetes
    bootstrap_cluster

    echo -e "\n${GREEN}Cluster '${CLUSTER_NAME}' deployment is complete!${NC}"
    echo -e "To access your cluster, run:${NC}"
    echo -e "  ${YELLOW}export KUBECONFIG=${HOME}/.kube/config_${CLUSTER_NAME}${NC}"
    echo -e "Then you can use kubectl, e.g.:${NC}"
    echo -e "  ${YELLOW}kubectl get nodes${NC}"

    echo "DEBUG: Script finished."
    exit 0
fi

# --- Action: destroy ---
if [[ "$ACTION" == "destroy" ]]; then
    if [[ "$#" -ne 1 ]]; then
        echo "Usage: $0 destroy <cluster_name>"
        exit 1
    fi
    CONFIG_FILE=$1
    # Check if the config file exists
    if [ ! -f "$CONFIG_FILE" ]; then
        die "Configuration file not found at: $CONFIG_FILE"
    fi

    # Load configuration from the file
    echo -e "${BLUE}[INFO] Loading configuration from $CONFIG_FILE...${NC}"
    source $CONFIG_FILE
    destroy_cluster
    exit 0
fi

# Main script logic based on action
case "$ACTION" in
    create)
        # The create logic is now self-contained within the 'if' block above
        ;;
    destroy)
        # The destroy logic is now self-contained within the 'if' block above
        ;;
    *)
        log "Invalid action. Use 'create' or 'destroy'."
        exit 1
        ;;
esac
