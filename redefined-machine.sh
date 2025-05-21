#!/bin/bash

#####################################
# 🧠 Steel Supreme Executor Installer
# 🔫 Project: BRN Sniper - redefined
# File: redefined-machine.sh
#####################################

LOG_PREFIX="🧠 [SteelSupremeInstaller]"
RPC_WARNING_LOG="❌ PRIVATE RPCS EXHAUSTED – USING PUBLIC RPCS"
PUBLIC_RPC_WARNING_INTERVAL=5
LAST_WARNING_TIME=0

# Constants for folders
T3RN_HOME="$HOME/t3rn"
ENV_FILE="$T3RN_HOME/.env"

mkdir -p "$T3RN_HOME"

# Public RPCs (hardcoded)
declare -A PUBLIC_RPCS
PUBLIC_RPCS["arbt"]="https://sepolia-rollup.arbitrum.io/rpc"
PUBLIC_RPCS["bast"]="https://sepolia.base.org"
PUBLIC_RPCS["opst"]="https://sepolia.optimism.io"
PUBLIC_RPCS["unit"]="https://unichain-sepolia.public-rpc.example"
PUBLIC_RPCS["monad"]="https://monad-sepolia.public-rpc.example"
PUBLIC_RPCS["sei"]="https://sei-sepolia.public-rpc.example"

# Detect or create .env
setup_env() {
    echo -e "$LOG_PREFIX Setting up environment variables..."
    if [[ ! -f $ENV_FILE ]]; then
        cat <<EOF > "$ENV_FILE"
ENVIRONMENT=testnet
LOG_LEVEL=debug
LOG_PRETTY=false
EXECUTOR_PROCESS_BIDS_ENABLED=true
EXECUTOR_PROCESS_ORDERS_ENABLED=true
EXECUTOR_PROCESS_CLAIMS_ENABLED=true
EXECUTOR_MAX_L3_GAS_PRICE=250000
EXECUTOR_PROCESS_BIDS_API_INTERVAL_SEC=1
EXECUTOR_MIN_BALANCE_THRESHOLD_ETH=0
EXECUTOR_ENABLE_BATCH_BIDDING=true
EXECUTOR_MAX_BATCH_SIZE=50
EXECUTOR_ORDER_PROCESS_PARALLELISM=50
EXECUTOR_OLD_ORDER_EXECUTION_WINDOW_SEC=3600
EXECUTOR_PROCESS_PENDING_ORDERS_FROM_API=false
EXECUTOR_PROCESS_ORDERS_API_ENABLED=false
EXECUTOR_ENABLED_NETWORKS="arbitrum-sepolia,base-sepolia,optimism-sepolia,blast-sepolia,monad-testnet,unichain-sepolia,sei-testnet"
EXECUTOR_ENABLED_ASSETS="eth,t3eth,t3mon,t3sei,mon,sei"
EOF
        echo -e "$LOG_PREFIX ✅ .env file created at $ENV_FILE"
    else
        echo -e "$LOG_PREFIX ⚠️  .env already exists — edit manually if needed."
    fi
}

# Intelligent RPC selector
get_rpc_for_chain() {
    local CHAIN=$1
    local PRIVATE=$(grep -i "${CHAIN}_PRIVATE_RPC=" "$ENV_FILE" | cut -d= -f2)
    local PUBLIC="${PUBLIC_RPCS[$CHAIN]}"

    if curl --max-time 3 --silent --fail -X POST -H "Content-Type: application/json"        --data '{"jsonrpc":"2.0","method":"eth_chainId","params":[],"id":1}' "$PRIVATE" | grep -q "result"; then
        echo "$PRIVATE"
    else
        now=$(date +%s)
        if (( now - LAST_WARNING_TIME >= PUBLIC_RPC_WARNING_INTERVAL )); then
            echo -e "$LOG_PREFIX $RPC_WARNING_LOG"
            LAST_WARNING_TIME=$now
        fi
        echo "$PUBLIC"
    fi
}

# Chain scan test (demo)
scan_chains() {
    echo -e "$LOG_PREFIX 🌐 Testing RPC connections..."
    for chain in "${!PUBLIC_RPCS[@]}"; do
        RPC=$(get_rpc_for_chain "$chain")
        echo -e "$LOG_PREFIX Using RPC for $chain → $RPC"
    done
}

# Installer Menu
main_menu() {
    echo "==============================="
    echo "🧠 Steel Supreme Executor - CLI"
    echo "🔫 Project: BRN Sniper"
    echo "==============================="
    echo "1. Setup .env configuration"
    echo "2. Scan chains & test RPCs"
    echo "3. Exit"
    echo "==============================="
    read -p "Choose an option [1-3]: " OPTION
    case $OPTION in
        1) setup_env ;;
        2) scan_chains ;;
        3) exit 0 ;;
        *) echo "❌ Invalid option. Try again." ;;
    esac
}

# Launch CLI
main_menu
