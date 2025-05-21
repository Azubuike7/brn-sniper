#!/bin/bash

ENV_FILE="$HOME/t3rn/.env"

confirm_prompt() {
    local prompt="$1"
    read -p "$prompt (y/N): " response
    response=$(echo "$response" | tr '[:upper:]' '[:lower:]' | xargs)
    [[ "$response" == "y" || "$response" == "yes" ]]
}

prompt_input() {
    local prompt="$1"
    local var
    read -p "$prompt" var
    echo "$var" | xargs
}

is_number() {
    [[ "$1" =~ ^[0-9]+$ ]]
}

install_package() {
    local package="$1"
    if command -v apt &>/dev/null; then
        sudo apt update && sudo apt install -y "$package"
    elif command -v yum &>/dev/null; then
        sudo yum install -y "$package"
    else
        echo "❌ Unsupported package manager. Install $package manually."
        exit 1
    fi
}

initialize_dynamic_network_data() {
    unset network_names executor_ids expected_chain_ids rpcs
    declare -gA network_names executor_ids expected_chain_ids rpcs

    for key in "${!networks[@]}"; do
        IFS="|" read -r name chain_id urls executor_id <<<"${networks[$key]}"
        network_names[$key]="$name"
        executor_ids[$key]="${executor_id:-$key}"
        expected_chain_ids[$key]="$chain_id"
        rpcs[$key]="$urls"
    done
}

declare -A networks=(
    [l2rn]="B2N Testnet|334|https://b2n.rpc.caldera.xyz/http|l2rn"
    [arbt]="Arbitrum Sepolia|421614|https://arbitrum-sepolia-rpc.publicnode.com https://sepolia-rollup.arbitrum.io/rpc|arbitrum-sepolia"
    [bast]="Base Sepolia|84532|https://base-sepolia-rpc.publicnode.com https://sepolia.base.org|base-sepolia"
    [blst]="Blast Sepolia|168587773|https://rpc.ankr.com/blast_testnet_sepolia https://sepolia.blast.io|blast-sepolia"
    [opst]="Optimism Sepolia|11155420|https://optimism-sepolia-rpc.publicnode.com https://sepolia.optimism.io|optimism-sepolia"
    [unit]="Unichain Sepolia|1301|https://unichain-sepolia-rpc.publicnode.com https://sepolia.unichain.org|unichain-sepolia"
    [mont]="Monad Testnet|10143|https://testnet-rpc.monad.xyz|monad-testnet"
    [seit]="Sei Testnet|1328|https://evm-rpc-testnet.sei-apis.com|sei-testnet"
    [bsct]="BNB Testnet|97|https://bnb-testnet.api.onfinality.io/public https://bsc-testnet-rpc.publicnode.com|binance-testnet"
    [opmn]="Optimism Mainnet|10|https://optimism-rpc.publicnode.com|optimism"
    [arbm]="Arbitrum Mainnet|42161|https://arbitrum-one-rpc.publicnode.com|arbitrum"
    [basm]="Base Mainnet|8453|https://base-rpc.publicnode.com|base"
)

load_env_file() {
    if [[ -f "$ENV_FILE" ]]; then
        set +a

        local vars_to_unset
        vars_to_unset=$(grep -o '^[A-Z_][A-Z0-9_]*' "$ENV_FILE" | xargs)
        [[ -n "$vars_to_unset" ]] && unset $vars_to_unset

        set -a
        source "$ENV_FILE"
        set +a

        if [[ -n "$RPC_ENDPOINTS" ]]; then
            if echo "$RPC_ENDPOINTS" | jq empty 2>/dev/null; then
                for key in $(echo "$RPC_ENDPOINTS" | jq -r 'keys[]'); do
                    urls=$(echo "$RPC_ENDPOINTS" | jq -r ".$key | @sh" | sed "s/'//g")
                    rpcs[$key]="$urls"
                done
            else
                echo "⚠️ RPC_ENDPOINTS is invalid JSON. Skipping import."
            fi
        else
            echo "ℹ️ No RPC_ENDPOINTS found. Using defaults."
            initialize_dynamic_network_data
        fi
    fi
}

required_tools=(sudo curl wget tar jq lsof nano)

if command -v apt &>/dev/null; then
    PKG_INSTALL="sudo apt update && sudo apt install -y"
elif command -v yum &>/dev/null; then
    PKG_INSTALL="sudo yum install -y"
else
    echo "❌ Supported package manager (apt or yum) not found. Cannot install dependencies."
    exit 1
fi

if ! command -v sudo &>/dev/null; then
    echo "⚠️  'sudo' is required but not installed."
    if confirm_prompt "📦  Install 'sudo' now?"; then
        if command -v apt &>/dev/null; then
            apt update && apt install -y sudo || {
                echo "❌ Failed to install 'sudo'. Exiting."
                exit 1
            }
        elif command -v yum &>/dev/null; then
            yum install -y sudo || {
                echo "❌ Failed to install 'sudo'. Exiting."
                exit 1
            }
        fi
    else
        echo "❌ Cannot continue without 'sudo'. Exiting."
        exit 1
    fi
fi

for tool in "${required_tools[@]}"; do
    [[ "$tool" == "sudo" ]] && continue
    if ! command -v "$tool" &>/dev/null; then
        echo "⚠️  '$tool' is not installed."
        if confirm_prompt "📦 Install '$tool' now?"; then
            if eval "$PKG_INSTALL $tool"; then
                echo ""
                echo "✅ '$tool' installed."
            else
                echo "❌ Failed to install '$tool'. Exiting."
                exit 1
            fi
        else
            echo "❌ '$tool' is required. Exiting."
            exit 1
        fi
    fi
done

load_env_file

get_executor_wallet_address() {
    grep -E '^\#?\s*EXECUTOR_WALLET_ADDRESS=' "$HOME/t3rn/.env" | cut -d= -f2
}

rebuild_rpc_endpoints() {
    local rpc_json=$(jq -n '{}')

    for key in "${!rpcs[@]}"; do
        urls_json=$(printf '%s\n' ${rpcs[$key]} | jq -R . | jq -s .)
        rpc_json=$(echo "$rpc_json" | jq --arg k "$key" --argjson v "$urls_json" '. + {($k): $v}')
    done

    export RPC_ENDPOINTS="$rpc_json"
}

wait_for_wallet_log_and_save() {
    local env_file="$HOME/t3rn/.env"
    local start_time=$(date +%s)
    local timeout=10

    while true; do
        address=$(journalctl -u t3rn-executor --no-pager -n 50 -r |
            grep '✅ Wallet loaded' |
            sed -n 's/.*\({.*\)/\1/p' |
            jq -r '.address' 2>/dev/null |
            grep -E '^0x[a-fA-F0-9]{40}' |
            head -n 1)

        if [[ -n "$address" ]]; then
            grep -q 'EXECUTOR_WALLET_ADDRESS=' "$env_file" || echo "# EXECUTOR_WALLET_ADDRESS=$address" >>"$env_file"
            break
        fi

        current_time=$(date +%s)
        elapsed=$((current_time - start_time))
        ((elapsed > timeout)) && break

        sleep 1
    done
}

install_executor_latest() {
    TAG=$(curl -s --max-time 5 --connect-timeout 3 https://api.github.com/repos/t3rn/executor-release/releases/latest | grep -Po '"tag_name": "\K.*?(?=")')
    if [[ -z "$TAG" ]]; then
        echo "❌ Failed to fetch latest version from GitHub."
        return
    fi
    run_executor_install "$TAG"
}

install_executor_specific() {
    input_version=$(prompt_input "🔢 Enter version (e.g. 0.60.0): ")
    if [[ -z "$input_version" ]]; then
        echo "↩️ No version entered. Returning."
        return
    fi
    TAG="v${input_version#v}"
    run_executor_install "$TAG"
}

run_executor_install() {
    local TAG="$1"

    for dir in "$HOME/t3rn" "$HOME/executor"; do
        if [[ -d "$dir" ]]; then
            echo "📁 Directory $(basename "$dir") exists."
            if confirm_prompt "❓ Remove it?"; then
                [[ "$(pwd)" == "$dir"* ]] && cd ~
                rm -rf "$dir"
            else
                echo "🚫 Installation cancelled."
                return
            fi
        fi
    done

    if lsof -i :9090 &>/dev/null; then
        pid_9090=$(lsof -ti :9090)
        [[ -n "$pid_9090" ]] && kill -9 "$pid_9090"
        sleep 1
    fi

    mkdir -p "$HOME/t3rn" && cd "$HOME/t3rn" || exit 1
    wget --quiet --show-progress https://github.com/t3rn/executor-release/releases/download/${TAG}/executor-linux-${TAG}.tar.gz
    tar -xzf executor-linux-${TAG}.tar.gz
    rm -f executor-linux-${TAG}.tar.gz
    cd executor/executor/bin || exit 1

    while true; do
        private_key=$(prompt_input "🔑 Enter PRIVATE_KEY_LOCAL: ")
        private_key=$(echo "$private_key" | sed 's/^0x//')
        if [[ -n "$private_key" ]]; then
            break
        fi

        echo ""
        echo "❓ Continue without private key?"
        echo ""
        echo "[1] 🔁 Retry"
        echo "[2] ⏩ Continue without key"
        echo ""
        echo "[0] ❌ Cancel"
        echo ""
        read -p "Select option [0-2]: " pk_choice
        echo ""
        case $pk_choice in
        1) continue ;;
        2) break ;;
        0)
            echo "❌ Cancelled."
            return
            ;;
        *) echo "❌ Invalid option." ;;
        esac
    done

    export PRIVATE_KEY_LOCAL="$private_key"
    if [[ -n "$RPC_ENDPOINTS" ]]; then
        if echo "$RPC_ENDPOINTS" | jq empty 2>/dev/null; then
            for key in $(echo "$RPC_ENDPOINTS" | jq -r 'keys[]'); do
                urls=$(echo "$RPC_ENDPOINTS" | jq -r ".$key | @sh" | sed "s/'//g")
                rpcs[$key]="$urls"
            done
        fi
    fi
    rebuild_rpc_endpoints
    rebuild_network_lists
    save_env_file
    load_env_file

    if ! validate_config_before_start; then
        echo "❌ Invalid configuration. Aborting."
        return
    fi

    sudo systemctl disable --now t3rn-executor.service 2>/dev/null
    sudo rm -f /etc/systemd/system/t3rn-executor.service
    sudo systemctl daemon-reload
    sleep 1
    create_systemd_unit
    wait_for_wallet_log_and_save &
    view_executor_logs
}

validate_config_before_start() {
    echo ""
    echo "🧪 Validating configuration..."
    local error=false

    [[ -z "$PRIVATE_KEY_LOCAL" || ! "$PRIVATE_KEY_LOCAL" =~ ^[a-fA-F0-9]{64}$ ]] && {
        echo "❌ Invalid PRIVATE_KEY_LOCAL."
        error=true
    }
    [[ -z "$RPC_ENDPOINTS" ]] && {
        echo "❌ RPC_ENDPOINTS is empty."
        error=true
    }
    ! echo "$RPC_ENDPOINTS" | jq empty &>/dev/null && {
        echo "❌ RPC_ENDPOINTS is not valid JSON."
        error=true
    }
    [[ -z "$EXECUTOR_ENABLED_NETWORKS" ]] && {
        echo "❌ No networks enabled."
        error=true
    }

    local bin_path="$HOME/t3rn/executor/executor/bin/executor"
    [[ ! -f "$bin_path" ]] && {
        echo "❌ Executor binary missing."
        error=true
    }
    [[ ! -x "$bin_path" ]] && {
        echo "❌ Executor binary not executable."
        error=true
    }

    for flag in EXECUTOR_PROCESS_PENDING_ORDERS_FROM_API EXECUTOR_PROCESS_ORDERS_API_ENABLED; do
        [[ "${!flag}" != "true" && "${!flag}" != "false" ]] && {
            echo "❌ $flag must be true/false."
            error=true
        }
    done

    available_space=$(df "$HOME" | awk 'NR==2 {print $4}')
    ((available_space < 500000)) && echo "⚠️ Less than 500MB free space."

    ! command -v systemctl &>/dev/null && {
        echo "❌ systemctl not found."
        error=true
    }
    ! sudo -n true 2>/dev/null && echo "⚠️ Sudo password might be required during setup."

    [[ "$error" == true ]] && return 1 || echo "✅ Configuration OK." && return 0
}

save_env_file() {
    mkdir -p "$HOME/t3rn"

    local wallet_comment=""
    if [[ -f "$ENV_FILE" ]]; then
        wallet_comment=$(grep '^# EXECUTOR_WALLET_ADDRESS=' "$ENV_FILE")
    fi

    rebuild_network_lists
    cat >"$ENV_FILE" <<EOF
#Your PRIVATE KEY is stored at the bottom

ENVIRONMENT=${ENVIRONMENT:-testnet}
LOG_LEVEL=${LOG_LEVEL:-debug}
LOG_PRETTY=${LOG_PRETTY:-false}
EXECUTOR_PROCESS_BIDS_ENABLED=${EXECUTOR_PROCESS_BIDS_ENABLED:-true}
EXECUTOR_PROCESS_ORDERS_ENABLED=${EXECUTOR_PROCESS_ORDERS_ENABLED:-true}
EXECUTOR_PROCESS_CLAIMS_ENABLED=${EXECUTOR_PROCESS_CLAIMS_ENABLED:-true}
EXECUTOR_PROCESS_PENDING_ORDERS_FROM_API=true
EXECUTOR_PROCESS_ORDERS_API_ENABLED=true
EXECUTOR_ENABLE_BATCH_BIDDING=${EXECUTOR_ENABLE_BATCH_BIDDING:-true}
EXECUTOR_API_SCAN_INTERVAL_SEC=${EXECUTOR_API_SCAN_INTERVAL_SEC:-5}
EXECUTOR_MAX_BATCH_SIZE=${EXECUTOR_MAX_BATCH_SIZE:-100}
EXECUTOR_ORDER_PROCESS_PARALLELISM=${EXECUTOR_ORDER_PROCESS_PARALLELISM:-100}
EXECUTOR_OLD_ORDER_EXECUTION_WINDOW_SEC=${EXECUTOR_OLD_ORDER_EXECUTION_WINDOW_SEC:-600}
EXECUTOR_MAX_L3_GAS_PRICE=${EXECUTOR_MAX_L3_GAS_PRICE:-950000}
EXECUTOR_PROCESS_BIDS_API_INTERVAL_SEC=${EXECUTOR_PROCESS_BIDS_API_INTERVAL_SEC:-0.1}
EXECUTOR_MIN_BALANCE_THRESHOLD_ETH=${EXECUTOR_MIN_BALANCE_THRESHOLD_ETH:-0}
PROMETHEUS_ENABLED=${PROMETHEUS_ENABLED:-false}

### This comment was created for convenience. It does not affect the operation of the Executor.

## EXECUTOR_ENABLED_ASSETS=eth,t3eth,t3mon,t3sei,mon,sei

EXECUTOR_ENABLED_NETWORKS=${EXECUTOR_ENABLED_NETWORKS}

NETWORKS_DISABLED=${NETWORKS_DISABLED}

### This comment was created for convenience. It does not affect the operation of the Executor.

## l2rn,arbitrum-sepolia,base-sepolia,unichain-sepolia,optimism-sepolia,blast-sepolia,sei-testnet,monad-testnet,optimism,arbitrum,base

# optimism,arbitrum,base - Mainnet Chain

RPC_ENDPOINTS='${RPC_ENDPOINTS}'



PRIVATE_KEY_LOCAL=${PRIVATE_KEY_LOCAL:-""}
EOF
    if [[ -n "$wallet_comment" ]]; then
        echo "$wallet_comment" >>"$ENV_FILE"
    fi
}

create_systemd_unit() {
    local unit_path="/etc/systemd/system/t3rn-executor.service"
    local exec_path="$HOME/t3rn/executor/executor/bin/executor"
    sudo bash -c "cat > $unit_path" <<EOF
[Unit]
Description=Executor Installer Service
After=network.target

[Service]
Type=simple
User=${SUDO_USER:-$USER}
WorkingDirectory=$(dirname "$exec_path")
EnvironmentFile=$ENV_FILE
ExecStart=$exec_path
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

    sudo systemctl daemon-reload
    sudo systemctl enable --now t3rn-executor
    systemctl is-active --quiet t3rn-executor && echo "🚀 Executor is running." || echo "❌ Executor failed to start."
}

rebuild_network_lists() {
    local default_disabled=(optimism arbitrum base)

    NETWORKS_DISABLED="${NETWORKS_DISABLED:-$(
        IFS=','
        echo "${default_disabled[*]}"
    )}"

    NETWORKS_DISABLED=$(echo "$NETWORKS_DISABLED" | tr ',' '\n' | awk '!seen[$0]++' | paste -sd, -)

    declare -A seen
    local enabled_networks=()

    for key in "${!executor_ids[@]}"; do
        executor_id="${executor_ids[$key]}"
        if [[ "$NETWORKS_DISABLED" != *"$executor_id"* && -z "${seen[$executor_id]}" ]]; then
            enabled_networks+=("$executor_id")
            seen[$executor_id]=1
        fi
    done

    EXECUTOR_ENABLED_NETWORKS="$(
        IFS=','
        echo "${enabled_networks[*]}"
    )"
}

configure_disabled_networks() {
    clear
    echo ""
    echo "🛑 Disable Networks"
    echo ""

    IFS=',' read -ra already_disabled <<<"$NETWORKS_DISABLED"
    declare -A already_disabled_lookup
    for net in "${already_disabled[@]}"; do
        already_disabled_lookup["$net"]=1
    done

    local i=1
    declare -A index_to_key
    for key in "${!executor_ids[@]}"; do
        exec_name="${executor_ids[$key]}"
        [[ -z "$exec_name" || -n "${already_disabled_lookup[$exec_name]}" ]] && continue
        echo "[$i] ${network_names[$key]}"
        index_to_key[$i]="$key"
        ((i++))
    done

    echo ""
    echo "[0] Back"
    index_to_key[0]="BACK"

    echo ""
    read -p "➡️ Enter numbers: " input
    [[ -z "$input" ]] && echo "" && echo "ℹ️ No changes." && return

    IFS=',' read -ra numbers <<<"$input"
    for number in "${numbers[@]}"; do
        [[ "${index_to_key[$number]}" == "BACK" ]] && return
    done

    declare -A selected
    for d in $input; do
        if ! is_number "$d" || [[ -z "${index_to_key[$d]}" ]]; then
            echo "❌ Invalid input: '$d'."
            return
        fi
        selected[$d]=1
    done

    local final_disabled=("${already_disabled[@]}")
    local newly_disabled=()
    for idx in "${!selected[@]}"; do
        key="${index_to_key[$idx]}"
        exec_name="${executor_ids[$key]}"
        final_disabled+=("$exec_name")
        newly_disabled+=("$exec_name")
    done

    if [[ ${#newly_disabled[@]} -eq 0 ]]; then
        echo "ℹ️ No networks selected to disable."
        return
    fi

    final_disabled_unique=($(echo "${final_disabled[@]}" | tr ' ' '\n' | awk '!seen[$0]++'))

    export NETWORKS_DISABLED="$(
        IFS=','
        echo "${final_disabled_unique[*]}"
    )"
    rebuild_network_lists
    rebuild_rpc_endpoints
    save_env_file

    echo ""
    echo "✅ Newly disabled networks:"
    for exec_id in "${newly_disabled[@]}"; do
        for key in "${!executor_ids[@]}"; do
            if [[ "${executor_ids[$key]}" == "$exec_id" ]]; then
                echo "   • ${network_names[$key]}"
                break
            fi
        done
    done
    echo ""
    if confirm_prompt "🔄 To apply the changes, the Executor must be restarted. Restart now?"; then
        if sudo systemctl restart t3rn-executor; then
            echo "✅ Executor restarted."
        else
            echo "❌ Failed to restart executor."
        fi
    else
        echo "ℹ️ You can restart manually later from the Main Menu."
    fi
}

enable_networks() {
    clear
    echo ""
    echo "✅ Enable Networks"
    echo ""
    [[ -z "$NETWORKS_DISABLED" ]] && echo "ℹ️ No networks disabled." && return
    IFS=',' read -ra disabled <<<"$NETWORKS_DISABLED"
    local i=1
    declare -A index_to_network

    for key in "${!networks[@]}"; do
        exec_name="${executor_ids[$key]}"
        for disabled_net in "${disabled[@]}"; do
            if [[ "$exec_name" == "$disabled_net" ]]; then
                echo "[$i] ${network_names[$key]}"
                index_to_network[$i]="$disabled_net"
                ((i++))
                break
            fi
        done
    done

    echo ""
    echo "[0] Back"
    index_to_key[0]="BACK"

    echo ""
    read -p "➡️ Enter numbers: " input
    [[ -z "$input" ]] && echo "" && echo "ℹ️ No changes." && return

    input=$(echo "$input" | tr -s ' ,')
    IFS=' ' read -ra numbers <<<"${input//,/ }"

    for number in "${numbers[@]}"; do
        [[ "$number" == "0" ]] && return
    done

    declare -A selected
    for d in "${numbers[@]}"; do
        if ! is_number "$d" || [[ -z "${index_to_network[$d]}" ]]; then
            echo "❌ Invalid input: '$d'."
            return
        fi
        selected[$d]=1
    done

    local remaining=()
    local reenabled=()
    for idx in "${!index_to_network[@]}"; do
        if [[ -n "${selected[$idx]}" ]]; then
            reenabled+=("${index_to_network[$idx]}")
        else
            remaining+=("${index_to_network[$idx]}")
        fi
    done

    if [[ ${#reenabled[@]} -eq 0 ]]; then
        echo "ℹ️ No networks selected to enable."
        return
    fi

    if [[ ${#remaining[@]} -eq 0 ]]; then
        export NETWORKS_DISABLED=""
        echo "✅ All networks enabled."
    else
        export NETWORKS_DISABLED="$(
            IFS=','
            echo "${remaining[*]}"
        )"
    fi
    if [[ -n "$RPC_ENDPOINTS" ]]; then
        if echo "$RPC_ENDPOINTS" | jq empty 2>/dev/null; then
            for key in $(echo "$RPC_ENDPOINTS" | jq -r 'keys[]'); do
                urls=$(echo "$RPC_ENDPOINTS" | jq -r ".$key | @sh" | sed "s/'//g")
                rpcs[$key]="$urls"
            done
        fi
    fi
    rebuild_network_lists
    for key in "${!networks[@]}"; do
        IFS="|" read -r _ chain_id urls executor_id <<<"${networks[$key]}"
        if [[ "$EXECUTOR_ENABLED_NETWORKS" == *"$executor_id"* && -z "${rpcs[$key]}" ]]; then
            rpcs[$key]="$urls"
        fi
    done
    rebuild_rpc_endpoints
    save_env_file

    echo ""
    echo "✅ Networks enabled:"
    for exec_id in "${reenabled[@]}"; do
        for key in "${!networks[@]}"; do
            executor_id="${executor_ids[$key]}"

            if [[ "${executor_ids[$key]}" == "$exec_id" ]]; then
                echo "   • ${network_names[$key]}"
                break
            fi
        done
    done
    echo ""
    if confirm_prompt "🔄 To apply the changes, the Executor must be restarted. Restart now?"; then
        if sudo systemctl restart t3rn-executor; then
            echo "✅ Executor restarted."
        else
            echo ""
            echo "❌ Failed to restart executor."
        fi
    else
        echo ""
        echo "ℹ️ You can restart manually later from the Main Menu."
    fi
}

uninstall_t3rn() {
    if ! confirm_prompt "❗ Completely remove Executor?"; then
        echo ""
        echo "🚫 Uninstall cancelled."
        return
    fi

    echo "🗑️ Uninstalling..."

    sudo rm -f "$ENV_FILE"
    sudo systemctl disable --now t3rn-executor.service 2>/dev/null
    sudo rm -f /etc/systemd/system/t3rn-executor.service
    sudo systemctl daemon-reload

    for dir in "$HOME/t3rn" "$HOME/executor"; do
        [[ -d "$dir" ]] && {
            [[ "$(pwd)" == "$dir"* ]] && cd ~
            rm -rf "$dir"
        }
    done

    sudo journalctl --rotate
    sudo journalctl --vacuum-time=1s

    unset ENVIRONMENT LOG_LEVEL LOG_PRETTY EXECUTOR_PROCESS_BIDS_ENABLED \
        EXECUTOR_PROCESS_ORDERS_ENABLED EXECUTOR_PROCESS_CLAIMS_ENABLED \
        EXECUTOR_PROCESS_PENDING_ORDERS_FROM_API EXECUTOR_PROCESS_ORDERS_API_ENABLED \
        EXECUTOR_MAX_L3_GAS_PRICE EXECUTOR_PROCESS_BIDS_API_INTERVAL_SEC \
        EXECUTOR_MIN_BALANCE_THRESHOLD_ETH PROMETHEUS_ENABLED PRIVATE_KEY_LOCAL \
        EXECUTOR_ENABLED_NETWORKS NETWORKS_DISABLED RPC_ENDPOINTS
    echo ""
    echo "✅ Executor removed."
}

initialize_dynamic_network_data

edit_rpc_menu() {
    clear
    echo ""
    echo "🌐 Edit RPC Endpoints"
    echo ""
    local changes_made=false

    IFS=',' read -ra disabled_networks <<<"$NETWORKS_DISABLED"
    declare -A disabled_lookup
    for dn in "${disabled_networks[@]}"; do
        disabled_lookup["$dn"]=1
    done

    for net in "${!networks[@]}"; do
        IFS="|" read -r name chain_id urls executor_id <<<"${networks[$net]}"
        [[ -n "${disabled_lookup[$executor_id]}" ]] && continue

        echo "🔗 $name"
        echo "Current: ${rpcs[$net]}"

        while true; do
            read -p "➡️ Enter new RPC URLs (space-separated, or Enter to skip): " input

            [[ -z "$input" ]] && echo "ℹ️ Skipped updating $name." && break

            local valid_urls=()
            local invalid=false

            for url in $input; do
                if [[ "$url" =~ ^https?:// ]]; then
                    echo "⏳ Checking RPC: $url ..."
                    local response=$(curl --silent --max-time 5 -X POST "$url" \
                        -H "Content-Type: application/json" \
                        --data '{"jsonrpc":"2.0","method":"eth_chainId","params":[],"id":1}')

                    local actual_chain_id_hex=$(echo "$response" | jq -r '.result')
                    [[ "$actual_chain_id_hex" == "null" || -z "$actual_chain_id_hex" ]] && {
                        echo "❌ Invalid or empty response: $url"
                        invalid=true
                        continue
                    }

                    local actual_chain_id_dec=$((16#${actual_chain_id_hex#0x}))
                    if [[ "$actual_chain_id_dec" == "$chain_id" ]]; then
                        valid_urls+=("$url")
                    else
                        echo "❌ Wrong ChainID: expected $chain_id, got $actual_chain_id_dec."
                        invalid=true
                    fi
                else
                    echo "❌ Invalid URL format (must start with http:// or https://): $url"
                    invalid=true
                fi
            done

            if [[ "$invalid" == false && "${#valid_urls[@]}" -gt 0 ]]; then
                rpcs[$net]="${valid_urls[*]}"
                changes_made=true
                echo ""
                echo "✅ Updated $name."
                break
            else
                echo "🚫 One or more URLs were invalid. Please re-enter RPCs for $name."
            fi
        done

        echo ""
    done

    if [[ "$changes_made" == true ]]; then
        rebuild_rpc_endpoints
        save_env_file
        echo "✅ RPC endpoints updated and saved."
        if confirm_prompt "🔄 To apply the changes, the Executor must be restarted. Restart now?"; then
            if sudo systemctl restart t3rn-executor; then
                echo ""
                echo "✅ Executor restarted."
            else
                echo ""
                echo "❌ Failed to restart executor."
            fi
        else
            echo ""
            echo "ℹ️ You can restart manually later from the Main Menu."
        fi
    else
        echo "ℹ️ No RPC changes made."
    fi
}

edit_env_file() {
    clear
    echo ""
    echo "📝 Edit Environment (.env) File"

    if [[ ! -f "$ENV_FILE" ]]; then
        echo ""
        echo "❌ .env file does not exist: $ENV_FILE"
        return
    fi

    echo ""
    echo "⚠️ WARNING: The .env file contains your PRIVATE KEY."
    echo "   Be careful not to share or leak this file."
    echo ""
    echo "ℹ️ After editing, you must restart the Executor to apply changes."
    echo ""
    if ! confirm_prompt "➡️ Continue editing .env file?"; then
        echo ""
        echo "🚫 Edit cancelled."
        return
    fi

    local editor=""
    if command -v nano &>/dev/null; then
        editor="nano"
    elif command -v vim &>/dev/null; then
        editor="vim"
    elif command -v vi &>/dev/null; then
        editor="vi"
    else
        echo "❌ No text editor found (nano, vim, vi)."
        return
    fi

    $editor "$ENV_FILE"
    echo ""
    echo "🔄 Don't forget to restart the executor using [11] Restart Executor."
}

check_balances() {
    clear
    wallet_address=$(get_executor_wallet_address)
    if [[ -z "$wallet_address" ]]; then
        wallet_address=$(prompt_input "🔑 Enter wallet address:")
        wallet_address=$(echo "$wallet_address" | xargs)
    fi

    echo ""
    echo "💰 Check Wallet Balances for: $wallet_address"

    [[ ! "$wallet_address" =~ ^0x[a-fA-F0-9]{40}$ ]] && echo "❌ Invalid address." && return

    echo "⏳ Fetching balances..."
    local url1="https://balancescan.xyz/balance/$wallet_address"
    local resp1=$(curl -s --max-time 5 --connect-timeout 3 "$url1")

    if [[ -z "$resp1" || "$resp1" =~ \"error\" ]]; then
        echo "❌ Failed to fetch from balancescan.xyz"
    else
        echo ""
        echo "📊 Live Balances:"
        echo ""
        echo "$resp1" | jq -r 'to_entries[] | "   • \(.key): \(.value) " + (if .key == "B2N Network" then "BRN" else "ETH" end)'
    fi

    echo ""
    echo "⏳ Fetching B2N balance history (last 5 days): "
    local url2="https://b2n.explorer.caldera.xyz/api/v2/addresses/$wallet_address/coin-balance-history-by-day"
    local resp2=$(curl -s --max-time 5 --connect-timeout 3 "$url2")

    if echo "$resp2" | jq -e .items >/dev/null 2>&1; then
        echo ""

        local history
        history=$(echo "$resp2" | jq -r '.items | reverse[] | "\(.date) \(.value)"' |
            awk '!seen[$1]++' | head -n 5)

        local i=0
        local today_balance yesterday_balance
        while read -r date wei; do
            echo "💸 BRN earned!"; BRN=$(awk "BEGIN { printf \"%.6f\", $wei / 1e18 }")
            printf "   • %s → %s BRN\n" "$date" "$BRN"
            if [[ $i -eq 0 ]]; then
                today_balance="$BRN"
            elif [[ $i -eq 1 ]]; then
                yesterday_balance="$BRN"
            fi
            ((i++))
        done <<<"$history"

        readarray -t daily_data < <(
            echo "$resp2" | jq -r '.items | reverse[] | "\(.date)|\(.value)"' |
                awk -F'|' '!seen[$1]++' | head -n 2
        )

        if [[ ${#daily_data[@]} -eq 2 ]]; then
            today_wei=$(echo "${daily_data[0]}" | cut -d'|' -f2)
            yesterday_wei=$(echo "${daily_data[1]}" | cut -d'|' -f2)

            if [[ -n "$today_wei" && -n "$yesterday_wei" ]]; then
                change_eth=$(awk "BEGIN { printf \"%.6f\", ($today_wei - $yesterday_wei) / 1e18 }")
                echo ""
                echo "📊 Change in last 24h: $change_eth BRN"
            else
                echo ""
                echo "❌ Failed to fetch B2N history."
            fi
        else
            echo ""
            echo "⚠️ Not enough unique days to calculate change."
        fi
    else
        echo ""
        echo "❌ Failed to fetch B2N history."
    fi

    echo ""
    read -p "↩️ Press Enter to return to menu..."
    clear
}

show_balance_change_history() {
    clear
    echo ""
    echo "📊 B2N Live Transactions:"
    echo ""

    wallet_address=$(get_executor_wallet_address)

    if [[ -z "$wallet_address" ]]; then
        wallet_address=$(prompt_input "🔑 Enter wallet address:")
        wallet_address=$(echo "$wallet_address" | xargs)
    fi

    if [[ ! "$wallet_address" =~ ^0x[a-fA-F0-9]{40}$ ]]; then
        echo "❌ Invalid address format."
        read -p "Press Enter to return..." && return
    fi

    tput civis
    trap "tput cnorm; stty echo; clear; return" EXIT

    local -a tx_lines=()
    local last_tx_hash=""

    resp=$(curl -s --max-time 5 --connect-timeout 3 "https://b2n.explorer.caldera.xyz/api/v2/addresses/$wallet_address/coin-balance-history")
    tx_lines=($(echo "$resp" | jq -r '.items[:20][] | "\(.block_timestamp)|\(.value)|\(.delta)|\(.transaction_hash)"'))
    last_tx_hash=$(echo "${tx_lines[0]}" | cut -d"|" -f4)

    draw_all_lines() {
        for i in "${!tx_lines[@]}"; do
            IFS="|" read -r timestamp value_raw delta_raw _ <<<"${tx_lines[$i]}"

            ts_epoch=$(date -u -d "$timestamp" +%s 2>/dev/null)
            [[ -z "$ts_epoch" || "$ts_epoch" -le 0 ]] && continue

            now_epoch=$(date +%s)
            diff_sec=$((now_epoch - ts_epoch))
            if ((diff_sec < 60)); then
                age="${diff_sec}s ago"
            else
                age="$((diff_sec / 60))m ago"
            fi

            delta_eth=$(awk "BEGIN { printf \"%.8f\", $delta_raw / 1e18 }")
            value_eth=$(awk "BEGIN { printf \"%.8f\", $value_raw / 1e18 }")
            arrow="▲"
            [[ "$delta_raw" =~ ^- ]] && arrow="▼"

            tput cup $((6 + i)) 0
            tput el
            printf " %-9s │ %-15s │ %s %s\n" "$age" "$value_eth" "$arrow" "$delta_eth"
        done
    }

    update_ages_only() {
        for i in "${!tx_lines[@]}"; do
            IFS="|" read -r timestamp _ _ _ <<<"${tx_lines[$i]}"
            ts_epoch=$(date -u -d "$timestamp" +%s 2>/dev/null)
            [[ -z "$ts_epoch" || "$ts_epoch" -le 0 ]] && continue

            now_epoch=$(date +%s)
            diff_sec=$((now_epoch - ts_epoch))
            if ((diff_sec < 60)); then
                age="${diff_sec}s ago"
            else
                age="$((diff_sec / 60))m ago"
            fi

            tput cup $((6 + i)) 0
            printf "%-10s" " "
            tput cup $((6 + i)) 0
            printf " %-10s" "$age"
        done
    }

    clear
    echo "📋 B2N Live Transactions - Press Enter to return to menu"
    echo ""
    echo "Wallet: $wallet_address"
    echo ""
    printf " %-9s │ %-15s │ %-10s\n" "Age" "Balance BRN" "Delta"
    echo "-----------┼-----------------┼-------------"
    draw_all_lines

    while true; do
        resp=$(curl -s "https://b2n.explorer.caldera.xyz/api/v2/addresses/$wallet_address/coin-balance-history")
        tx=$(echo "$resp" | jq -r '.items[0] | "\(.block_timestamp)|\(.value)|\(.delta)|\(.transaction_hash)"')

        [[ "$tx" == "|||" || -z "$tx" ]] && sleep 1 && continue

        IFS="|" read -r timestamp value_raw delta_raw tx_hash <<<"$tx"

        if [[ "$tx_hash" != "$last_tx_hash" ]]; then
            tx_lines=("$tx" "${tx_lines[@]}")
            tx_lines=("${tx_lines[@]:0:20}")
            last_tx_hash="$tx_hash"
            draw_all_lines
        else
            update_ages_only
        fi

        read -t 0.5 -n 1 -s -r key </dev/tty
        [[ $? -eq 0 && "$key" == "" ]] && break
    done

    tput cnorm
    echo ""
    clear
}

view_executor_logs() {
    if systemctl list-units --type=service --all | grep -q 't3rn-executor.service'; then
        sudo journalctl -u t3rn-executor -f --no-pager --output=cat
    else
        echo "❌ Executor not found. It might not be installed or has been removed."
        echo ""
    fi
}

show_support_menu() {
    clear
    echo "🆘 Executor Installer - Help & Support"
    echo ""
    echo "📖 GitHub:"
    echo "   https://github.com/Steel/executor-installer"
    echo ""
    echo "🌐 Discord nickname:"
    echo "   Steel"
    echo ""
    read -p "Press Enter to return to the main menu..."
    clear
}

main_menu() {
    while true; do
        echo "===================================="
        echo "  ⚙️ Executor Installer Main Menu"
        echo "             by Steel🍌"
        echo "===================================="
        echo ""
        echo "[1] 📦 Install / Uninstall Executor"
        echo "[2] 🔎 View Executor Logs"
        echo "[3] 🛠️ Configuration"
        echo "[4] 💰 Wallet Tools"
        echo "[5] 🔁 Restart Executor"
        echo "[6] 🆘 Help & Support"
        echo ""
        echo "[0] Exit"
        echo ""
        read -p "➡️ Select option [0-6]: " section
        echo ""
        clear
        case $section in
        1) menu_installation ;;
        2) view_executor_logs ;;
        3) menu_configuration ;;
        5)
            clear
            echo "🔁 Restarting executor..."
            if sudo systemctl restart t3rn-executor; then
                echo "✅ Executor restarted." && sleep 0.35
            else
                echo "❌ Failed to restart executor." && echo "" && sleep 0.35
            fi
            ;;
        4) menu_wallet_tools ;;
        6) show_support_menu ;;
        0)
            echo "👋 Goodbye!"
            exit 0
            ;;
        *) echo "❌ Invalid option." && echo "" && sleep 0.35 ;;
        esac
    done
}

menu_installation() {
    while true; do
        echo ""
        echo "====== 📦 Installation Menu ======"
        echo ""
        echo "[1] Install latest version"
        echo "[2] Install specific version"
        echo "[3] Uninstall Executor"
        echo ""
        echo "[0] Back"
        echo ""
        read -p "➡️ Select option [0-3]: " opt
        echo ""
        clear
        case $opt in
        1) install_executor_latest ;;
        2) install_executor_specific ;;
        3) uninstall_t3rn ;;
        0) return ;;
        *) echo "❌ Invalid option." && sleep 0.35 ;;
        esac
    done
}

menu_configuration() {
    while true; do
        echo ""
        echo "====== 🛠️ Configuration Menu ======"
        echo ""
        echo "[1] Edit RPC Endpoints"
        echo "[2] Show Configured RPC"
        echo "[3] Set Max L3 Gas Price"
        echo "[4] Configure Order API Flags"
        echo "[5] Set / Update Private Key"
        echo "[6] Edit .env File"
        echo "[7] Disable Networks"
        echo "[8] Enable Networks"
        echo ""
        echo "[0] Back"
        echo ""
        read -p "➡️ Select option [0-8]: " opt
        echo ""
        clear
        case $opt in
        1) edit_rpc_menu ;;
        2)
            clear
            echo ""
            echo "🌐 Current RPC Endpoints:"
            echo ""
            declare -A rpcs
            while IFS="=" read -r key value; do
                rpcs["$key"]="$value"
            done < <(
                echo "$RPC_ENDPOINTS" |
                    jq -r 'to_entries[] | "\(.key)=" + (.value | join(" "))'
            )

            IFS=',' read -ra disabled_networks <<<"$NETWORKS_DISABLED"
            declare -A disabled_lookup
            for dn in "${disabled_networks[@]}"; do
                disabled_lookup["$dn"]=1
            done

            for net in "${!networks[@]}"; do
                executor_id="${executor_ids[$net]}"
                [[ -n "${disabled_lookup[$executor_id]}" ]] && continue

                echo "- ${network_names[$net]}:"
                if [[ -n "${rpcs[$net]}" ]]; then
                    for url in ${rpcs[$net]}; do
                        echo "   • $url"
                    done
                else
                    echo "   ⚠️ No RPC configured."
                fi
                echo ""
            done
            ;;
        3)
            clear
            echo ""
            gas=$(prompt_input "⛽ Enter new Max L3 gas price: ")
            if is_number "$gas"; then
                export EXECUTOR_MAX_L3_GAS_PRICE=$gas
                save_env_file
                echo "✅ New gas price set to $EXECUTOR_MAX_L3_GAS_PRICE."
                if confirm_prompt "🔄 To apply the changes, the Executor must be restarted. Restart now?"; then
                    if sudo systemctl restart t3rn-executor; then
                        echo "✅ Executor restarted."
                    else
                        echo ""
                        echo "❌ Failed to restart executor."
                    fi
                else
                    echo ""
                    echo "ℹ️ You can restart manually later from the Main Menu."
                fi
            else
                echo ""
                echo "ℹ️ No changes."
            fi
            ;;
        4)
            clear
            echo ""
            val1=$(prompt_input "🔧 EXECUTOR_PROCESS_PENDING_ORDERS_FROM_API (true/false): ")
            val2=$(prompt_input "🔧 EXECUTOR_PROCESS_ORDERS_API_ENABLED (true/false): ")
            if [[ "$val1" =~ ^(true|false)$ && "$val2" =~ ^(true|false)$ ]]; then
                export EXECUTOR_PROCESS_PENDING_ORDERS_FROM_API=$val1
                export EXECUTOR_PROCESS_ORDERS_API_ENABLED=$val2
                save_env_file
                echo "✅ Order API flags updated."
                if confirm_prompt "🔄 To apply the changes, the Executor must be restarted. Restart now?"; then
                    if sudo systemctl restart t3rn-executor; then
                        echo "✅ Executor restarted."
                    else
                        echo ""
                        echo "❌ Failed to restart executor."
                    fi
                else
                    echo ""
                    echo "ℹ️ You can restart manually later from the Main Menu."
                fi
            else
                echo ""
                echo "ℹ️ No changes."
            fi
            ;;
        5)
            clear
            echo ""
            pk=$(prompt_input "🔑 Enter new PRIVATE_KEY_LOCAL: ")
            pk=$(echo "$pk" | sed 's/^0x//' | xargs)
            if [[ -n "$pk" ]]; then
                export PRIVATE_KEY_LOCAL=$pk
                save_env_file
                echo ""
                echo "✅ Private key updated."
                if confirm_prompt "🔄 To apply the changes, the Executor must be restarted. Restart now?"; then
                    if sudo systemctl restart t3rn-executor; then
                        echo ""
                        echo "✅ Executor restarted."
                    else
                        echo ""
                        echo "❌ Failed to restart executor."
                    fi
                else
                    echo ""
                    echo "ℹ️ You can restart manually later from the Main Menu."
                fi
            else
                echo ""
                echo "ℹ️ No input. Private key unchanged."
            fi
            ;;
        6) edit_env_file ;;
        7) configure_disabled_networks ;;
        8) enable_networks ;;
        0) return ;;
        *) echo "❌ Invalid option." && sleep 0.35 ;;
        esac
    done
}

menu_wallet_tools() {
    while true; do
        echo ""
        echo "====== 💰 Wallet Tools ======"
        echo ""
        echo "[1] Check Wallet Balances"
        echo "[2] Check Last txn"
        echo ""
        echo "[0] Back"
        echo ""
        read -p "➡️ Select option [0-2]: " opt
        echo ""
        clear
        case $opt in
        1) check_balances ;;
        2) show_balance_change_history ;;
        0) return ;;
        *) echo "❌ Invalid option." && sleep 0.35 ;;
        esac
    done
}

main_menu



# Email alert if private RPCs fail
if ! command -v mail &>/dev/null; then
    echo "Installing mailutils..."
    sudo apt update && sudo apt install -y mailutils
fi

WALLET=$(grep 'EXECUTOR_WALLET_ADDRESS=' "$HOME/t3rn/.env" | cut -d= -f2)
HOST_IP=$(curl -s ifconfig.me || hostname -I | awk '{print $1}')
echo "Private RPCs failed on VPS with Wallet: $WALLET (IP: $HOST_IP)" | mail -s "[STEEL EXECUTOR] Private RPCs Exhausted" steelazubuike@gmail.com
