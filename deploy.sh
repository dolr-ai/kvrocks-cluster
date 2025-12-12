#!/bin/bash
# Kvrocks Cluster Deployment Script
#
# Unified script that handles:
# 1. Deploying docker-compose to all nodes via SSH
# 2. Starting Kvrocks containers on each node
# 3. Setting up cluster topology (node IDs, slot distribution)
# 4. Verifying cluster health
#
# Prerequisites:
# - SSH config with aliases: kvrocks-master-1, kvrocks-master-2, kvrocks-replica-1, kvrocks-replica-2
# - redis-cli installed locally
#
# Usage:
#   ./deploy.sh              # Full deployment (deploy + setup + verify)
#   ./deploy.sh deploy       # Only deploy containers
#   ./deploy.sh setup        # Only setup cluster topology
#   ./deploy.sh verify       # Only verify cluster health
#   ./deploy.sh stop         # Stop all containers

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${SCRIPT_DIR}/config.yml"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Check and install yq if needed
ensure_yq() {
    if ! command -v yq &> /dev/null; then
        echo -e "${YELLOW}yq not found. Installing...${NC}"
        if [[ "$OSTYPE" == "darwin"* ]]; then
            brew install yq
        elif [[ "$OSTYPE" == "linux-gnu"* ]]; then
            sudo wget -qO /usr/local/bin/yq https://github.com/mikefarah/yq/releases/latest/download/yq_linux_amd64
            sudo chmod +x /usr/local/bin/yq
        else
            echo -e "${RED}Please install yq manually: https://github.com/mikefarah/yq${NC}"
            exit 1
        fi
    fi
}

# Read config values
# this env will only be stored locally
read_config() {
    # Load password from .env file
    if [ -f "${SCRIPT_DIR}/.env" ]; then
        source "${SCRIPT_DIR}/.env"
        PASSWORD="$KVROCKS_PASSWORD"
    else
        echo -e "${RED}ERROR: .env file not found. Create it with KVROCKS_PASSWORD=your_password${NC}"
        exit 1
    fi

    if [ -z "$PASSWORD" ]; then
        echo -e "${RED}ERROR: KVROCKS_PASSWORD not set in .env${NC}"
        exit 1
    fi

    PORT=$(yq '.cluster.port' "$CONFIG_FILE")
    WORKERS=$(yq '.cluster.workers' "$CONFIG_FILE")
    TOPOLOGY_VERSION=$(yq '.cluster.topology_version' "$CONFIG_FILE")
    NODE_COUNT=$(yq '.nodes | length' "$CONFIG_FILE")
}

# Get node property by index
get_node() {
    local index=$1
    local prop=$2
    yq ".nodes[$index].$prop" "$CONFIG_FILE"
}

# Deploy docker-compose to a single node
deploy_node() {
    local ssh_alias=$1
    local container_name=$2

    echo -e "  Deploying to ${YELLOW}${ssh_alias}${NC}..."

    # Copy docker-compose.yml
    scp -q "${SCRIPT_DIR}/docker-compose.yml" "${ssh_alias}:~/docker-compose.yml"

    # Pull image and start container
    # Create temporary .env FIRST (needed for pull validation), run docker compose, then delete .env
    ssh "${ssh_alias}" "cd ~ && echo 'CONTAINER_NAME=${container_name}' > .env && echo 'KVROCKS_PASSWORD=${PASSWORD}' >> .env && docker compose pull -q && docker compose up -d && rm -f .env"

    echo -e "  ${GREEN}${ssh_alias}: Started${NC}"
}

# Stop container on a node
stop_node() {
    local ssh_alias=$1
    echo -e "  Stopping ${YELLOW}${ssh_alias}${NC}..."
    ssh "${ssh_alias}" "cd ~ && docker compose down" 2>/dev/null || true
    echo -e "  ${GREEN}${ssh_alias}: Stopped${NC}"
}

# Deploy to all nodes
deploy_all() {
    echo -e "${GREEN}=== Deploying Kvrocks to all nodes ===${NC}"
    echo ""

    for ((i=0; i<NODE_COUNT; i++)); do
        local name=$(get_node $i "name")
        local ssh_alias=$(get_node $i "ssh_alias")
        local container_name="kvrocks-${name}"
        deploy_node "$ssh_alias" "$container_name"
    done

    echo ""
    echo -e "${GREEN}All nodes deployed. Waiting for startup...${NC}"
    sleep 5
}

# Stop all nodes
stop_all() {
    echo -e "${YELLOW}=== Stopping all Kvrocks nodes ===${NC}"
    echo ""

    for ((i=0; i<NODE_COUNT; i++)); do
        local ssh_alias=$(get_node $i "ssh_alias")
        stop_node "$ssh_alias"
    done

    echo ""
    echo -e "${GREEN}All nodes stopped.${NC}"
}

# Generate deterministic node ID from name and IP
generate_node_id() {
    local name=$1
    local ip=$2
    echo -n "kvrocks-${name}-${ip}" | shasum -a 256 | cut -c1-40
}

# Run redis-cli command on a node
run_redis() {
    local ip=$1
    shift
    REDISCLI_AUTH="$PASSWORD" redis-cli -h "$ip" -p "$PORT" "$@"
}

# Setup cluster topology
setup_cluster() {
    echo -e "${GREEN}=== Setting up cluster topology ===${NC}"
    echo ""

    # Step 1: Verify connectivity
    echo "Step 1: Verifying connectivity..."
    for ((i=0; i<NODE_COUNT; i++)); do
        local ip=$(get_node $i "ip")
        local name=$(get_node $i "name")
        local pong=$(run_redis "$ip" PING 2>/dev/null || echo "FAILED")
        if [ "$pong" != "PONG" ]; then
            echo -e "  ${RED}ERROR: Cannot connect to ${name} (${ip})${NC}"
            echo "  Make sure Kvrocks is running and password is correct"
            exit 1
        fi
        echo -e "  ${GREEN}${name} (${ip}): OK${NC}"
    done
    echo ""

    # Step 2: Generate and set node IDs
    echo "Step 2: Setting node IDs..."
    for ((i=0; i<NODE_COUNT; i++)); do
        local name=$(get_node $i "name")
        local ip=$(get_node $i "ip")
        local node_id=$(generate_node_id "$name" "$ip")
        run_redis "$ip" CLUSTERX SETNODEID "$node_id" > /dev/null
        echo -e "  ${name}: ${node_id}"
    done
    echo ""

    # Step 3: Build topology string
    echo "Step 3: Building cluster topology..."
    TOPOLOGY=""
    for ((i=0; i<NODE_COUNT; i++)); do
        local name=$(get_node $i "name")
        local ip=$(get_node $i "ip")
        local role=$(get_node $i "role")
        local node_id=$(generate_node_id "$name" "$ip")

        if [ "$role" == "master" ]; then
            local slots=$(get_node $i "slots")
            TOPOLOGY+="${node_id} ${ip} ${PORT} master - ${slots}"
        else
            local master_name=$(get_node $i "master")
            # Find master's IP and generate its node ID
            local master_ip=$(yq ".nodes[] | select(.name == \"$master_name\") | .ip" "$CONFIG_FILE")
            local master_id=$(generate_node_id "$master_name" "$master_ip")
            TOPOLOGY+="${node_id} ${ip} ${PORT} slave ${master_id}"
        fi

        # Add newline between entries (except last)
        if [ $i -lt $((NODE_COUNT - 1)) ]; then
            TOPOLOGY+=$'\n'
        fi
    done

    echo "Topology:"
    echo "--------------------------------------------"
    echo "$TOPOLOGY"
    echo "--------------------------------------------"
    echo ""

    # Step 4: Apply topology to all nodes
    echo "Step 4: Applying topology to all nodes (version ${TOPOLOGY_VERSION})..."
    for ((i=0; i<NODE_COUNT; i++)); do
        local name=$(get_node $i "name")
        local ip=$(get_node $i "ip")
        run_redis "$ip" CLUSTERX SETNODES "$TOPOLOGY" $TOPOLOGY_VERSION > /dev/null
        echo -e "  ${GREEN}${name}: OK${NC}"
    done
    echo ""

    echo -e "${GREEN}Cluster topology applied successfully!${NC}"
}

# Verify cluster health
verify_cluster() {
    echo -e "${GREEN}=== Kvrocks Cluster Health Check ===${NC}"
    echo ""

    local healthy=0
    local unhealthy=0

    for ((i=0; i<NODE_COUNT; i++)); do
        local name=$(get_node $i "name")
        local ip=$(get_node $i "ip")
        local role=$(get_node $i "role")

        echo -e "--- ${YELLOW}${name}${NC} (${ip}) ---"

        # Ping test
        local pong=$(run_redis "$ip" PING 2>/dev/null || echo "FAILED")
        if [ "$pong" == "PONG" ]; then
            echo -e "  Ping: ${GREEN}OK${NC}"
            ((healthy++))
        else
            echo -e "  Ping: ${RED}FAILED${NC}"
            ((unhealthy++))
            echo ""
            continue
        fi

        # Get replication role
        local actual_role=$(run_redis "$ip" INFO replication 2>/dev/null | grep "^role:" | tr -d '\r')
        echo "  $actual_role"

        # Get cluster state
        local state=$(run_redis "$ip" CLUSTER INFO 2>/dev/null | grep "^cluster_state:" | tr -d '\r')
        echo "  $state"

        echo ""
    done

    echo "============================================"
    echo "Full Cluster Nodes View"
    echo "============================================"
    local first_ip=$(get_node 0 "ip")
    run_redis "$first_ip" CLUSTER NODES

    echo ""
    echo "============================================"
    echo -e "Summary: ${GREEN}${healthy} healthy${NC}, ${RED}${unhealthy} unhealthy${NC}"
    echo "============================================"

    if [ $unhealthy -eq 0 ]; then
        echo -e "${GREEN}All nodes are healthy!${NC}"
        return 0
    else
        echo -e "${RED}WARNING: Some nodes are unhealthy!${NC}"
        return 1
    fi
}

# Print usage
usage() {
    echo "Usage: $0 [command]"
    echo ""
    echo "Commands:"
    echo "  deploy    Deploy containers to all nodes"
    echo "  setup     Setup cluster topology"
    echo "  verify    Verify cluster health"
    echo "  stop      Stop all containers"
    echo "  (none)    Full deployment: deploy + setup + verify"
}

# Main
main() {
    ensure_yq
    read_config

    local command=${1:-"full"}

    case $command in
        deploy)
            deploy_all
            ;;
        setup)
            setup_cluster
            ;;
        verify)
            verify_cluster
            ;;
        stop)
            stop_all
            ;;
        full)
            deploy_all
            setup_cluster
            verify_cluster
            ;;
        -h|--help|help)
            usage
            ;;
        *)
            echo -e "${RED}Unknown command: $command${NC}"
            usage
            exit 1
            ;;
    esac
}

main "$@"
