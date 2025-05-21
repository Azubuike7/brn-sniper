#!/bin/bash

############################################
# 🧠 Steel Supreme Executor - BRN Sniper   #
# 🔧 Full Installer & CLI with Aggressive Logic
# 📂 Filename: redefined-machine.sh
############################################

T3RN_HOME="$HOME/t3rn"
ENV_FILE="$T3RN_HOME/.env"
LOG_PREFIX="🧠 [SteelSupremeInstaller]"
PRIVATE_RPC_WARNING="❌ PRIVATE RPCS EXHAUSTED – USING PUBLIC RPCS"
LAST_WARNING_TIME=0
RPC_WARNING_INTERVAL=5

mkdir -p "$T3RN_HOME"

# --- Hardcoded Public RPCs (never overwritten) ---
declare -A PUBLIC_RPCS
PUBLIC_RPCS["arbt"]="https://sepolia-rollup.arbitrum.io/rpc"
PUBLIC_RPCS["bast"]="https://sepolia.base.org"
PUBLIC_RPCS["opst"]="https://sepolia.optimism.io"
PUBLIC_RPCS["unit"]="https://unichain-sepolia.public-rpc.example"
PUBLIC_RPCS["monad"]="https://monad-sepolia.public-rpc.example"
PUBLIC_RPCS["sei"]="https://sei-sepolia.public-rpc.example"

# --- CLI Menu ---
main_menu() {
    clear
    echo "============================================"
    echo "🧠 Steel Supreme Executor - BRN Sniper v2.0"
    echo "🚀 Redefined Aggressive Installer & Manager"
    echo "============================================"
    echo "1️⃣  Install & Configure Environment"
    echo "2️⃣  Scan RPCs and Show Chain Status"
    echo "3️⃣  Start Executor"
    echo "4️⃣  Exit"
    echo "============================================"
    read -p "👉 Choose an option [1-4]: " OPTION

    case $OPTION in
        1) setup_env ;;
        2) scan_chains ;;
        3) run_executor ;;
        4) exit 0 ;;
        *) echo "❌ Invalid option"; sleep 2; main_menu ;;
    esac
}

# --- Environment Setup ---
setup_env() {
    echo -e "$LOG_PREFIX 🔧 Creating .env file with optimized BRN settings..."
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
    echo -e "$LOG_PREFIX ✅ .env configured at $ENV_FILE"
    sleep 2
    main_menu
}

# --- Get RPC with fallback ---
get_rpc_for_chain() {
    local CHAIN=$1
    local PRIVATE=$(grep -i "${CHAIN}_PRIVATE_RPC=" "$ENV_FILE" | cut -d= -f2)
    local PUBLIC="${PUBLIC_RPCS[$CHAIN]}"

    if curl --max-time 3 --silent --fail -X POST -H "Content-Type: application/json"        --data '{"jsonrpc":"2.0","method":"eth_chainId","params":[],"id":1}' "$PRIVATE" | grep -q "result"; then
        echo "$PRIVATE"
    else
        now=$(date +%s)
        if (( now - LAST_WARNING_TIME >= RPC_WARNING_INTERVAL )); then
            echo -e "$LOG_PREFIX $PRIVATE_RPC_WARNING"
            LAST_WARNING_TIME=$now
        fi
        echo "$PUBLIC"
    fi
}

# --- RPC Test ---
scan_chains() {
    echo -e "$LOG_PREFIX 🌐 Scanning available chains..."
    for chain in "${!PUBLIC_RPCS[@]}"; do
        RPC=$(get_rpc_for_chain "$chain")
        echo -e "$LOG_PREFIX ✅ $chain → $RPC"
    done
    read -p "Press enter to return to menu..." dummy
    main_menu
}

# --- Executor Start Placeholder ---
run_executor() {
    echo -e "$LOG_PREFIX 🏁 Launching executor with supreme settings..."
    echo -e "$LOG_PREFIX 🔥 Aggressive BRN engine active. Monitor logs for 💸 rewards and ⚔️ bid performance."
    # In actual use, place executor launch command here
    sleep 2
    main_menu
}

# --- Start Menu ---
main_menu
