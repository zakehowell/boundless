#!/bin/bash

# 颜色变量
CYAN='\033[0;36m'
LIGHTBLUE='\033[1;34m'
RED='\033[0;31m'
GREEN='\033[0;32m'
PURPLE='\033[0;35m'
YELLOW='\033[1;33m'
BOLD='\033[1m'
RESET='\033[0m'

# 常量
SCRIPT_NAME="$(basename "$0")"
SCRIPT_VERSION="1.0.0"
LOG_FILE="/var/log/boundless_prover_setup.log"
ERROR_LOG="/var/log/boundless_prover_error.log"
INSTALL_DIR="$HOME/boundless"
COMPOSE_FILE="$INSTALL_DIR/compose.yml"
BROKER_CONFIG="$INSTALL_DIR/broker.toml"

# 退出码
EXIT_SUCCESS=0
EXIT_OS_CHECK_FAILED=1
EXIT_DPKG_ERROR=2
EXIT_DEPENDENCY_FAILED=3
EXIT_GPU_ERROR=4
EXIT_NETWORK_ERROR=5
EXIT_USER_ABORT=6
EXIT_UNKNOWN=99

# 标志
ALLOW_ROOT=false
FORCE_RECLONE=false
START_IMMEDIATELY=false
NON_INTERACTIVE=false

# 网络配置
declare -A NETWORKS=(
    ["base"]="Base 主网*0x0b144e07a0826182b6b59788c34b32bfa86fb711*0x26759dbB201aFbA361Bec78E097Aa3942B0b4AB8*0x8C5a8b5cC272Fe2b74D18843CF9C3aCBc952a760*https://base-mainnet.beboundless.xyz"
    ["base-sepolia"]="Base Sepolia 测试网*0x0b144e07a0826182b6b59788c34b32bfa86fb711*0x6B7ABa661041164b8dB98E30AE1454d2e9D5f14b*0x8C5a8b5cC272Fe2b74D18843CF9C3aCBc952a760*https://base-sepolia.beboundless.xyz"
    ["eth-sepolia"]="Ethereum Sepolia 测试网*0x925d8331ddc0a1F0d96E68CF073DFE1d92b69187*0x13337C76fE2d1750246B68781ecEe164643b98Ec*0x7aAB646f23D1392d4522CFaB0b7FB5eaf6821d64*https://eth-sepolia.beboundless.xyz/"
)

# 处理错误
handle_error() {
    local msg="$1"
    local exit_code="$2"
    error "$msg"
    case $exit_code in
        $EXIT_DPKG_ERROR)
            echo -e "${RED}检测到 DPKG 配置错误！${RESET}"
            echo -e "${YELLOW}请运行：dpkg --configure -a${RESET}"
            ;;
        $EXIT_OS_CHECK_FAILED)
            echo -e "${RED}操作系统检查失败！${RESET}"
            ;;
        $EXIT_DEPENDENCY_FAILED)
            echo -e "${RED}依赖安装失败！${RESET}"
            ;;
        $EXIT_GPU_ERROR)
            echo -e "${RED}GPU 配置错误！${RESET}"
            ;;
        $EXIT_NETWORK_ERROR)
            echo -e "${RED}网络配置错误！${RESET}"
            ;;
        $EXIT_USER_ABORT)
            echo -e "${YELLOW}用户取消安装${RESET}"
            ;;
        *)
            echo -e "${RED}未知错误！${RESET}"
            ;;
    esac
    exit "$exit_code"
}

# 重试网络操作
with_retry() {
    local cmd="$1"
    local retries=3
    local delay=5
    for ((i=1; i<=retries; i++)); do
        info "尝试 $i/$retries: $cmd"
        if eval "$cmd" >> "$LOG_FILE" 2>&1; then
            return 0
        fi
        warning "尝试 $i 失败，$delay 秒后重试..."
        sleep $delay
    done
    handle_error "命令失败，尝试 $retries 次后仍未成功：$cmd" $EXIT_DEPENDENCY_FAILED
}

# 检查磁盘空间
check_disk_space() {
    local required_space=20
    local available_space
    available_space=$(df -h --output=avail "$HOME" | tail -1 | tr -d ' ')
    available_space=$(echo "$available_space" | sed 's/G//')
    if (( $(echo "$available_space < $required_space" | bc -l) )); then
        handle_error "磁盘空间不足。需要：${required_space}GB，可用：${available_space}GB" $EXIT_DEPENDENCY_FAILED
    fi
    info "磁盘空间充足：${available_space}GB"
}