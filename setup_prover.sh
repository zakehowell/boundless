#!/bin/bash

set -euo pipefail

# 加载配置文件
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

# 中文函数定义
info() {
    local msg="$1"
    local func="${FUNCNAME[1]}"
    printf "${CYAN}[信息]${RESET} %s\n" "$msg"
    echo "[信息] $(date '+%Y-%m-%d %H:%M:%S') [$func] - $msg" >> "$LOG_FILE"
}

success() {
    local msg="$1"
    printf "${GREEN}[成功]${RESET} %s\n" "$msg"
    echo "[成功] $(date '+%Y-%m-%d %H:%M:%S') - $msg" >> "$LOG_FILE"
}

error() {
    local msg="$1"
    local func="${FUNCNAME[1]}"
    printf "${RED}[错误]${RESET} %s\n" "$msg" >&2
    echo "[错误] $(date '+%Y-%m-%d %H:%M:%S') [$func] - $msg" >> "$LOG_FILE"
    echo "[错误] $(date '+%Y-%m-%d %H:%M:%S') [$func] - $msg" >> "$ERROR_LOG"
}

warning() {
    local msg="$1"
    printf "${YELLOW}[警告]${RESET} %s\n" "$msg"
    echo "[警告] $(date '+%Y-%m-%d %H:%M:%S') - $msg" >> "$LOG_FILE"
}

prompt() {
    printf "${PURPLE}[输入]${RESET} %s" "$1"
}

# 检查 dpkg 状态
check_dpkg_status() {
    if dpkg --audit 2>&1 | grep -q "dpkg was interrupted"; then
        error "dpkg 被中断，需要手动修复"
        return 1
    fi
    return 0
}

# 检查操作系统兼容性
check_os() {
    info "检查操作系统兼容性..."
    if [[ ! -f /etc/os-release ]]; then
        handle_error "/etc/os-release 未找到，无法确定操作系统" $EXIT_OS_CHECK_FAILED
    fi
    . /etc/os-release
    if [[ "${ID,,}" != "ubuntu" ]]; then
        handle_error "不支持的操作系统：$NAME。本脚本仅支持 Ubuntu" $EXIT_OS_CHECK_FAILED
    elif [[ "${VERSION_ID,,}" != "22.04" && "${VERSION_ID,,}" != "20.04" ]]; then
        warning "脚本在 Ubuntu 20.04/22.04 上测试，当前版本：$VERSION_ID"
        prompt "是否继续？(y/N): "
        read -r response
        if [[ ! "$response" =~ ^[yY]$ ]]; then
            exit $EXIT_USER_ABORT
        fi
    else
        info "操作系统：$PRETTY_NAME"
    fi
}

# 检查命令是否存在
command_exists() {
    command -v "$1" &> /dev/null
}

# 检查软件包是否已安装
is_package_installed() {
    dpkg -s "$1" &> /dev/null
}

# 更新系统
update_system() {
    info "更新系统软件包..."
    if ! check_dpkg_status; then
        exit $EXIT_DPKG_ERROR
    fi
    update_apt
    if ! apt upgrade -y >> "$LOG_FILE" 2>&1; then
        handle_error "apt 升级失败" $EXIT_DEPENDENCY_FAILED
    fi
    success "系统软件包已更新"
}

# 安装软件包
install_package() {
    local package="$1"
    info "安装 $package..."
    if ! check_dpkg_status; then
        exit $EXIT_DPKG_ERROR
    fi
    if ! apt install -y "$package" >> "$LOG_FILE" 2>&1; then
        handle_error "安装 $package 失败" $EXIT_DEPENDENCY_FAILED
    fi
    success "$package 已安装"
}

# 更新 apt 包列表
update_apt() {
    info "更新包列表..."
    if ! apt update -y >> "$LOG_FILE" 2>&1; then
        handle_error "apt 更新失败" $EXIT_DEPENDENCY_FAILED
    fi
    success "包列表已更新"
}

# 安装基本依赖
install_basic_deps() {
    local packages=(
        curl iptables build-essential git wget lz4 jq make gcc nano
        automake autoconf tmux htop nvme-cli libgbm1 pkg-config
        libssl-dev tar clang bsdmainutils ncdu unzip libleveldb-dev
        libclang-dev ninja-build nvtop ubuntu-drivers-common
        gnupg ca-certificates lsb-release postgresql-client
    )
    info "安装基本依赖..."
    printf "${CYAN}进度: ["
    for pkg in "${packages[@]}"; do
        install_package "$pkg" &
        printf "."
    done
    wait
    printf "]${RESET}\n"
    success "基本依赖已安装"
}

# 安装 Docker
install_docker() {
    if command_exists docker; then
        info "Docker 已安装"
        return
    fi
    info "安装 Docker..."
    if ! check_dpkg_status; then
        exit $EXIT_DPKG_ERROR
    fi
    install_package "apt-transport-https"
    install_package "ca-certificates"
    install_package "curl"
    install_package "gnupg-agent"
    install_package "software-properties-common"
    with_retry "curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg"
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null
    update_apt
    install_package "docker-ce"
    install_package "docker-ce-cli"
    install_package "containerd.io"
    install_package "docker-compose-plugin"
    systemctl enable docker
    systemctl start docker
    usermod -aG docker "$(logname 2>/dev/null || echo "$USER")"
    success "Docker 已安装"
}

# 安装 NVIDIA 容器工具包
install_nvidia_toolkit() {
    if is_package_installed "nvidia-docker2"; then
        info "NVIDIA 容器工具包已安装"
        return
    fi
    info "安装 NVIDIA 容器工具包..."
    if ! check_dpkg_status; then
        exit $EXIT_DPKG_ERROR
    fi
    local distribution
    distribution=$(grep '^ID=' /etc/os-release | cut -d'=' -f2 | tr -d '"')$(grep '^VERSION_ID=' /etc/os-release | cut -d'=' -f2 | tr -d '"' | tr -d '\.')
    with_retry "curl -s -L https://nvidia.github.io/nvidia-docker/gpgkey | apt-key add -"
    with_retry "curl -s -L https://nvidia.github.io/nvidia-docker/$distribution/nvidia-docker.list | tee /etc/apt/sources.list.d/nvidia-docker.list"
    update_apt
    install_package "nvidia-docker2"
    mkdir -p /etc/docker
    tee /etc/docker/daemon.json <<EOF
{
    "default-runtime": "nvidia",
    "runtimes": {
        "nvidia": {
            "path": "nvidia-container-runtime",
            "runtimeArgs": []
        }
    }
}
EOF
    systemctl restart docker
    success "NVIDIA 容器工具包已安装"
}

# 安装 Rust
install_rust() {
    if command_exists rustc; then
        info "Rust 已安装"
        return
    fi
    info "安装 Rust..."
    with_retry "curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y"
    source "$HOME/.cargo/env"
    with_retry "rustup update"
    success "Rust 已安装"
}

# 安装 Just
install_just() {
    if command_exists just; then
        info "Just 已安装"
        return
    fi
    info "安装 Just 命令运行器..."
    with_retry "curl --proto '=https' --tlsv1.2 -sSf https://just.systems/install.sh | bash -s -- --to /usr/local/bin"
    success "Just 已安装"
}

# 安装 Rust 依赖
install_rust_deps() {
    info "安装 Rust 依赖..."
    source "$HOME/.cargo/env" || handle_error "无法加载 $HOME/.cargo/env" $EXIT_DEPENDENCY_FAILED
    install_cargo
    install_rzup
    install_cargo_risczero
    install_bento_client
    install_boundless_cli
    echo 'export PATH="$HOME/.cargo/bin:$HOME/.risc0/bin:$PATH"' >> ~/.bashrc
    PS1='' source ~/.bashrc || handle_error "无法加载 ~/.bashrc" $EXIT_DEPENDENCY_FAILED
    success "Rust 依赖已安装"
}

# 安装 cargo
install_cargo() {
    if command_exists cargo; then
        info "Cargo 已安装"
        return
    fi
    install_package "cargo"
}

# 安装 rzup
install_rzup() {
    info "安装 rzup..."
    with_retry "curl -L https://risczero.com/install | bash"
    export PATH="$PATH:$HOME/.risc0/bin"
    rzup install rust >> "$LOG_FILE" 2>&1 || handle_error "安装 RISC Zero Rust 工具链失败" $EXIT_DEPENDENCY_FAILED
}

# 安装 cargo-risczero
install_cargo_risczero() {
    if command_exists cargo-risczero; then
        info "cargo-risczero 已安装"
        return
    fi
    info "安装 cargo-risczero..."
    with_retry "cargo install cargo-risczero"
    with_retry "rzup install cargo-risczero"
}

# 安装 bento-client
install_bento_client() {
    info "安装 bento-client..."
    local toolchain
    toolchain=$(rustup toolchain list | grep risc0 | head -1)
    if [[ -z "$toolchain" ]]; then
        handle_error "未找到 RISC Zero 工具链" $EXIT_DEPENDENCY_FAILED
    fi
    with_retry "RUSTUP_TOOLCHAIN=$toolchain cargo install --git https://github.com/risc0/risc0 bento-client --bin bento_cli"
}

# 安装 boundless-cli
install_boundless_cli() {
    info "安装 boundless-cli..."
    with_retry "cargo install --locked boundless-cli"
}

# 克隆 Boundless 仓库
clone_repository() {
    info "设置 Boundless 仓库..."
    if [[ -d "$INSTALL_DIR" ]]; then
        if [[ "$FORCE_RECLONE" == "true" ]]; then
            warning "强制删除现有目录 $INSTALL_DIR"
            rm -rf "$INSTALL_DIR"
        else
            warning "Boundless 目录已存在于 $INSTALL_DIR"
            prompt "是否删除并重新克隆？(y/N): "
            read -r response
            if [[ "$response" =~ ^[yY]$ ]]; then
                rm -rf "$INSTALL_DIR"
            else
                cd "$INSTALL_DIR"
                if ! git pull origin release-0.10 >> "$LOG_FILE" 2>&1; then
                    handle_error "更新仓库失败" $EXIT_DEPENDENCY_FAILED
                fi
                return
            fi
        fi
    fi
    with_retry "git clone https://github.com/boundless-xyz/boundless $INSTALL_DIR"
    cd "$INSTALL_DIR"
    with_retry "git checkout release-0.10"
    with_retry "git submodule update --init --recursive"
    success "仓库已克隆并初始化"
}

# 检测 GPU 配置
detect_gpus() {
    info "检测 GPU 配置..."
    if ! command_exists nvidia-smi; then
        handle_error "未找到 nvidia-smi，GPU 驱动可能未正确安装" $EXIT_GPU_ERROR
    fi
    local gpu_info
    gpu_info=$(nvidia-smi --query-gpu=index,memory.total --format=csv,noheader,nounits 2>/dev/null)
    if [[ -z "$gpu_info" ]]; then
        handle_error "未检测到 GPU" $EXIT_GPU_ERROR
    fi
    GPU_COUNT=$(echo "$gpu_info" | wc -l)
    info "发现 $GPU_COUNT 个 GPU"
    GPU_MEMORY=()
    while IFS=',' read -r idx mem; do
        mem=$(echo "$mem" | tr -d ' ')
        GPU_MEMORY+=("$mem")
        info "GPU $idx: ${mem}MB VRAM"
    done <<< "$gpu_info"
    MIN_VRAM=$(printf '%s\n' "${GPU_MEMORY[@]}" | sort -n | head -1)
    if [[ $MIN_VRAM -ge 40000 ]]; then
        SEGMENT_SIZE=22
    elif [[ $MIN_VRAM -ge 20000 ]]; then
        SEGMENT_SIZE=21
    elif [[ $MIN_VRAM -ge 16000 ]]; then
        SEGMENT_SIZE=20
    elif [[ $MIN_VRAM -ge 12000 ]]; then
        SEGMENT_SIZE=19
    elif [[ $MIN_VRAM -ge 8000 ]]; then
        SEGMENT_SIZE=18
    else
        SEGMENT_SIZE=17
    fi
    info "根据最小 VRAM ${MIN_VRAM}MB 设置 SEGMENT_SIZE=$SEGMENT_SIZE"
}

# 配置 compose.yml 文件
configure_compose() {
    info "正在为 $GPU_COUNT 张 GPU 配置 compose.yml..."

    # 如果只有 1 张 GPU，使用默认 compose.yml，不需要额外配置
    if [[ $GPU_COUNT -eq 1 ]]; then
        info "检测到单张 GPU，使用默认 compose.yml"
        return
    fi

    # 生成 compose.yml 基础结构
    cat > "$COMPOSE_FILE" << 'EOF'
name: bento

# 公共环境变量锚点
x-base-environment: &base-environment
  DATABASE_URL: postgresql://${POSTGRES_USER:-worker}:${POSTGRES_PASSWORD:-password}@${POSTGRES_HOST:-postgres}:${POSTGRES_PORT:-5432}/${POSTGRES_DB:-taskdb}
  REDIS_URL: redis://${REDIS_HOST:-redis}:6379
  S3_URL: http://${MINIO_HOST:-minio}:9000
  S3_BUCKET: ${MINIO_BUCKET:-workflow}
  S3_ACCESS_KEY: ${MINIO_ROOT_USER:-admin}
  S3_SECRET_KEY: ${MINIO_ROOT_PASS:-password}
  RUST_LOG: ${RUST_LOG:-info}
  RUST_BACKTRACE: 1

# Agent 公共配置
x-agent-common: &agent-common
  image: risczero/risc0-bento-agent:stable@sha256:c6fcc92686a5d4b20da963ebba3045f09a64695c9ba9a9aa984dd98b5ddbd6f9
  restart: always
  runtime: nvidia
  depends_on:
    - postgres
    - redis
    - minio
  environment:
    <<: *base-environment

# Exec Agent 公共配置
x-exec-agent-common: &exec-agent-common
  <<: *agent-common
  mem_limit: 4G
  cpus: 3
  environment:
    <<: *base-environment
    RISC0_KECCAK_PO2: ${RISC0_KECCAK_PO2:-17}
  entrypoint: /app/agent -t exec --segment-po2 ${SEGMENT_SIZE:-21}

services:
  # Redis 服务
  redis:
    hostname: ${REDIS_HOST:-redis}
    image: ${REDIS_IMG:-redis:7.2.5-alpine3.19}
    restart: always
    ports:
      - 6379:6379
    volumes:
      - redis-data:/data

  # PostgreSQL 数据库服务
  postgres:
    hostname: ${POSTGRES_HOST:-postgres}
    image: ${POSTGRES_IMG:-postgres:16.3-bullseye}
    restart: always
    environment:
      POSTGRES_DB: ${POSTGRES_DB:-taskdb}
      POSTGRES_USER: ${POSTGRES_USER:-worker}
      POSTGRES_PASSWORD: ${POSTGRES_PASSWORD:-password}
    expose:
      - '${POSTGRES_PORT:-5432}'
    ports:
      - '${POSTGRES_PORT:-5432}:${POSTGRES_PORT:-5432}'
    volumes:
      - postgres-data:/var/lib/postgresql/data
    command: -p ${POSTGRES_PORT:-5432}

  # MinIO 对象存储服务
  minio:
    hostname: ${MINIO_HOST:-minio}
    image: ${MINIO_IMG:-minio/minio:RELEASE.2024-05-28T17-19-04Z}
    ports:
      - '9000:9000'
      - '9001:9001'
    volumes:
      - minio-data:/data
    command: server /data --console-address ":9001"
    environment:
      - MINIO_ROOT_USER=${MINIO_ROOT_USER:-admin}
      - MINIO_ROOT_PASSWORD=${MINIO_ROOT_PASS:-password}
      - MINIO_DEFAULT_BUCKETS=${MINIO_BUCKET:-workflow}
    healthcheck:
      test: ["CMD", "mc", "ready", "local"]
      interval: 5s
      timeout: 5s
      retries: 5

  # Grafana 监控服务
  grafana:
    image: ${GRAFANA_IMG:-grafana/grafana:11.0.0}
    restart: unless-stopped
    ports:
     - '3000:3000'
    environment:
      - GF_SECURITY_ADMIN_USER=admin
      - GF_SECURITY_ADMIN_PASSWORD=admin
      - GF_LOG_LEVEL=WARN
      - POSTGRES_HOST=${POSTGRES_HOST:-postgres}
      - POSTGRES_DB=${POSTGRES_DB:-taskdb}
      - POSTGRES_PORT=${POSTGRES_PORT:-5432}
      - POSTGRES_USER=${POSTGRES_USER:-worker}
      - POSTGRES_PASS=${POSTGRES_PASSWORD:-password}
      - GF_INSTALL_PLUGINS=frser-sqlite-datasource
    volumes:
      - ./dockerfiles/grafana:/etc/grafana/provisioning/
      - grafana-data:/var/lib/grafana
      - broker-data:/db
    depends_on:
      - postgres
      - redis
      - minio

  # 执行 agent（exec）
  exec_agent0:
    <<: *exec-agent-common

  exec_agent1:
    <<: *exec-agent-common

  # 辅助 agent
  aux_agent:
    <<: *agent-common
    mem_limit: 256M
    cpus: 1
    entrypoint: /app/agent -t aux --monitor-requeue

EOF

    # 为每个 GPU 添加独立的 prove agent 配置
    for i in $(seq 0 $((GPU_COUNT - 1))); do
        cat >> "$COMPOSE_FILE" << EOF
  gpu_prove_agent$i:
    <<: *agent-common
    mem_limit: 4G
    cpus: 4
    entrypoint: /app/agent -t prove
    deploy:
      resources:
        reservations:
          devices:
            - driver: nvidia
              device_ids: ['$i']
              capabilities: [gpu]

EOF
    done

    # 添加 snark agent、REST API、broker 服务配置
    cat >> "$COMPOSE_FILE" << 'EOF'
  snark_agent:
    <<: *agent-common
    entrypoint: /app/agent -t snark
    ulimits:
      stack: 90000000

  rest_api:
    image: risczero/risc0-bento-rest-api:stable@sha256:7b5183811675d0aa3646d079dec4a7a6d47c84fab4fa33d3eb279135f2e59207
    restart: always
    depends_on:
      - postgres
      - minio
    mem_limit: 1G
    cpus: 1
    environment:
      <<: *base-environment
    ports:
      - '8081:8081'
    entrypoint: /app/rest_api --bind-addr 0.0.0.0:8081 --snark-timeout ${SNARK_TIMEOUT:-180}

  broker:
    restart: always
    depends_on:
      - rest_api
EOF

    # 将所有 GPU agent 加入 broker 依赖列表
    for i in $(seq 0 $((GPU_COUNT - 1))); do
        echo "      - gpu_prove_agent$i" >> "$COMPOSE_FILE"
    done

    # 补充 broker 的其他依赖及配置
    cat >> "$COMPOSE_FILE" << 'EOF'
      - exec_agent0
      - exec_agent1
      - aux_agent
      - snark_agent
      - redis
      - postgres
    profiles: [broker]
    build:
      context: .
      dockerfile: dockerfiles/broker.dockerfile
    mem_limit: 2G
    cpus: 2
    stop_grace_period: 3h
    volumes:
      - type: bind
        source: ./broker.toml
        target: /app/broker.toml
      - broker-data:/db/
    network_mode: host
    environment:
      RUST_LOG: ${RUST_LOG:-info,broker=debug,boundless_market=debug}
      PRIVATE_KEY: ${PRIVATE_KEY}
      RPC_URL: ${RPC_URL}
      ORDER_STREAM_URL:
      POSTGRES_HOST:
      POSTGRES_DB:
      POSTGRES_PORT:
      POSTGRES_USER:
      POSTGRES_PASS:
    entrypoint: /app/broker --db-url 'sqlite:///db/broker.db' --set-verifier-address ${SET_VERIFIER_ADDRESS} --boundless-market-address ${BOUNDLESS_MARKET_ADDRESS} --config-file /app/broker.toml --bento-api-url http://localhost:8081

# 定义持久化存储卷
volumes:
  redis-data:
  postgres-data:
  minio-data:
  grafana-data:
  broker-data:
EOF

    # 输出成功信息
    success "compose.yml 已为 $GPU_COUNT 张 GPU 配置完成"
}


# 配置网络
configure_network() {
    info "配置网络设置..."
    local options=("Base 主网" "Base Sepolia 测试网" "Ethereum Sepolia 测试网")
    arrow_menu "${options[@]}"
    local choice=$?
    case $choice in
        0) NETWORK="base" ;;
        1) NETWORK="base-sepolia" ;;
        2) NETWORK="eth-sepolia" ;;
        *) handle_error "无效的网络选择" $EXIT_NETWORK_ERROR ;;
    esac
    IFS='*' read -r NETWORK_NAME VERIFIER_ADDRESS BOUNDLESS_MARKET_ADDRESS SET_VERIFIER_ADDRESS ORDER_STREAM_URL <<< "${NETWORKS[$NETWORK]}"
    info "已选择：$NETWORK_NAME"
    warning "你的私钥将存储在配置文件中，请确保其安全！"
    echo -e "\n${BOLD}RPC 配置说明：${RESET}"
    echo "RPC 必须支持 eth_blockNumber。推荐提供商："
    echo "- Alchemy"
    echo "- BlockPi (Base 网络免费)"
    echo "- Chainstack (设置 lookback_blocks=0)"
    echo "- 自建节点 RPC"
    prompt "请输入 RPC 地址："
    read -r RPC_URL
    if [[ -z "$RPC_URL" ]]; then
        handle_error "RPC 地址不能为空" $EXIT_USER_ABORT
    fi
    prompt "请输入钱包私钥（64 位十六进制，无 0x 前缀）："
    read -rs PRIVATE_KEY
    echo
    if [[ ! "$PRIVATE_KEY" =~ ^[0-9a-fA-F]{64}$ ]]; then
        handle_error "私钥必须为 64 位十六进制字符" $EXIT_NETWORK_ERROR
    fi
    cat > "$INSTALL_DIR/.env.broker" << EOF
# 网络：$NETWORK_NAME
export VERIFIER_ADDRESS=$VERIFIER_ADDRESS
export BOUNDLESS_MARKET_ADDRESS=$BOUNDLESS_MARKET_ADDRESS
export SET_VERIFIER_ADDRESS=$SET_VERIFIER_ADDRESS
export ORDER_STREAM_URL="$ORDER_STREAM_URL"
export RPC_URL="$RPC_URL"
export PRIVATE_KEY=$PRIVATE_KEY
export SEGMENT_SIZE=$SEGMENT_SIZE

# 证明节点配置
RUST_LOG=info
REDIS_HOST=redis
REDIS_IMG=redis:7.2.5-alpine3.19
POSTGRES_HOST=postgres
POSTGRES_IMG=postgres:16.3-bullseye
POSTGRES_DB=taskdb
POSTGRES_PORT=5432
POSTGRES_USER=worker
POSTGRES_PASSWORD=password
MINIO_HOST=minio
MINIO_IMG=minio/minio:RELEASE.2024-05-28T17-19-04Z
MINIO_ROOT_USER=admin
MINIO_ROOT_PASS=password
MINIO_BUCKET=workflow
GRAFANA_IMG=grafana/grafana:11.0.0
RISC0_KECCAK_PO2=17
EOF
    # 其他 .env 文件配置类似
    chown "$(logname 2>/dev/null || echo "$USER")" "$INSTALL_DIR/.env."*
    chmod 600 "$INSTALL_DIR/.env."*
    success "网络配置已保存，权限已设置"
}

# 配置 broker.toml
configure_broker() {
    info "配置 broker 设置..."
    cp "$INSTALL_DIR/broker-template.toml" "$BROKER_CONFIG"
    echo -e "\n${BOLD}Broker 配置说明：${RESET}"
    echo "请设置关键参数（按 Enter 使用默认值）："
    prompt "mcycle_price（每百万周期价格，默认：0.0000005）："
    read -r mcycle_price
    mcycle_price=${mcycle_price:-0.0000005}
    prompt "peak_prove_khz（最大证明速度 kHz，默认：100）："
    read -r peak_prove_khz
    peak_prove_khz=${peak_prove_khz:-100}
    prompt "max_mcycle_limit（最大接受周期，百万，默认：8000）："
    read -r max_mcycle_limit
    max_mcycle_limit=${max_mcycle_limit:-8000}
    prompt "min_deadline（最短截止时间秒，默认：300）："
    read -r min_deadline
    min_deadline=${min_deadline:-300}
    prompt "max_concurrent_proofs（最大并行证明，默认：2）："
    read -r max_concurrent_proofs
    max_concurrent_proofs=${max_concurrent_proofs:-2}
    prompt "lockin_priority_gas（锁定交易额外 gas，Gwei，默认：0）："
    read -r lockin_priority_gas
    sed -i "s/mcycle_price = \"[^\"]*\"/mcycle_price = \"$mcycle_price\"/" "$BROKER_CONFIG"
    sed -i "s/peak_prove_khz = [0-9]*/peak_prove_khz = $peak_prove_khz/" "$BROKER_CONFIG"
    sed -i "s/max_mcycle_limit = [0-9]*/max_mcycle_limit = $max_mcycle_limit/" "$BROKER_CONFIG"
    sed -i "s/min_deadline = [0-9]*/min_deadline = $min_deadline/" "$BROKER_CONFIG"
    sed -i "s/max_concurrent_proofs = [0-9]*/max_concurrent_proofs = $max_concurrent_proofs/" "$BROKER_CONFIG"
    if [[ -n "$lockin_priority_gas" ]]; then
        sed -i "s/#lockin_priority_gas = [0-9]*/lockin_priority_gas = $lockin_priority_gas/" "$BROKER_CONFIG"
    fi
    chown "$(logname 2>/dev/null || echo "$USER")" "$BROKER_CONFIG"
    chmod 600 "$BROKER_CONFIG"
    success "Broker 配置已保存，权限已设置"
}

# 创建管理脚本
create_management_script() {
    info "创建管理脚本..."
    cat > "$INSTALL_DIR/prover.sh" << 'EOF'
#!/bin/bash

export PATH="$HOME/.cargo/bin:$PATH"

INSTALL_DIR="$(dirname "$0")"
cd "$INSTALL_DIR"

# 颜色变量
CYAN='\033[0;36m'
LIGHTBLUE='\033[1;34m'
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
PURPLE='\033[0;35m'
ORANGE='\033[0;33m'
BOLD='\033[1m'
RESET='\033[0m'
GRAY='\033[0;90m'

# 菜单选项
declare -a menu_items=(
    "服务:服务管理"
    "启动 Broker"
    "启动 Bento（仅测试）"
    "停止服务"
    "查看日志"
    "健康检查"
    "备份:备份配置"
    "备份配置文件"
    "配置:配置管理"
    "更改网络"
    "更改私钥"
    "编辑 Broker 配置"
    "质押:质押管理"
    "存入质押"
    "检查质押余额"
    "性能:性能测试"
    "运行基准测试（订单 ID）"
    "监控:系统监控"
    "监控 GPU"
    "更新:检查更新"
    "检查更新"
    "退出"
)

# 绘制菜单
draw_menu() {
    local current=$1
    clear
    echo -e "${BOLD}${CYAN}╔══════════════════════════════════════════╗${RESET}"
    echo -e "${BOLD}${CYAN}║      Boundless Prover 管理脚本          ║${RESET}"
    echo -e "${BOLD}${CYAN}╚══════════════════════════════════════════╝${RESET}"
    echo

    local index=0
    for item in "${menu_items[@]}"; do
        if [[ $item == *":"* ]]; then
            if [[ $item == "SEPARATOR:" ]]; then
                echo -e "${GRAY}──────────────────────────────────────────${RESET}"
            else
                local category=$(echo $item | cut -d: -f1)
                local desc=$(echo $item | cut -d: -f2)
                case $category in
                    "服务")
                        echo -e "\n${BOLD}${GREEN}▶ $desc${RESET}"
                        ;;
                    "备份")
                        echo -e "\n${BOLD}${BLUE}▶ $desc${RESET}"
                        ;;
                    "配置")
                        echo -e "\n${BOLD}${YELLOW}▶ $desc${RESET}"
                        ;;
                    "质押")
                        echo -e "\n${BOLD}${PURPLE}▶ $desc${RESET}"
                        ;;
                    "性能")
                        echo -e "\n${BOLD}${ORANGE}▶ $desc${RESET}"
                        ;;
                    "监控")
                        echo -e "\n${BOLD}${LIGHTBLUE}▶ $desc${RESET}"
                        ;;
                    "更新")
                        echo -e "\n${BOLD}${CYAN}▶ $desc${RESET}"
                        ;;
                esac
            fi
        else
            if [ $index -eq $current ]; then
                echo -e "  ${BOLD}${CYAN}→ $item${RESET}"
            else
                echo -e "    $item"
            fi
            ((index++))
        fi
    done
    echo
    echo -e "${GRAY}使用 ↑/↓ 键导航，Enter 确认，q 退出${RESET}"
}

# 获取菜单项
get_menu_item() {
    local current=$1
    local index=0
    for item in "${menu_items[@]}"; do
        if [[ ! $item == *":"* ]]; then
            if [ $index -eq $current ]; then
                echo "$item"
                return
            fi
            ((index++))
        fi
    done
}

# 获取按键
get_key() {
    local key
    IFS= read -rsn1 key 2>/dev/null >&2
    if [[ $key = "" ]]; then echo enter; fi
    if [[ $key = $'\x1b' ]]; then
        read -rsn2 key
        if [[ $key = [A ]]; then echo up; fi
        if [[ $key = [B ]]; then echo down; fi
    fi
    if [[ $key = "q" ]] || [[ $key = "Q" ]]; then echo quit; fi
}

# 验证配置
validate_config() {
    local errors=0
    if [[ ! -f .env.broker ]]; then
        echo -e "${RED}✗ 未找到 .env.broker 配置文件${RESET}"
        ((errors++))
    else
        source .env.broker
        if [[ ! "$PRIVATE_KEY" =~ ^[0-9a-fA-F]{64}$ ]]; then
            echo -e "${RED}✗ 私钥格式无效${RESET}"
            ((errors++))
        fi
        if [[ -z "$RPC_URL" ]]; then
            echo -e "${RED}✗ 未配置 RPC 地址${RESET}"
            ((errors++))
        fi
        if [[ -z "$BOUNDLESS_MARKET_ADDRESS" ]] || [[ -z "$SET_VERIFIER_ADDRESS" ]]; then
            echo -e "${RED}✗ 未配置必要的合约地址${RESET}"
            ((errors++))
        fi
    fi
    return $errors
}

# 箭头菜单
arrow_menu() {
    local -a options=("$@")
    local current=0
    local key
    while true; do
        clear
        for i in "${!options[@]}"; do
            if [ $i -eq $current ]; then
                echo -e "${BOLD}${CYAN}→ ${options[$i]}${RESET}"
            else
                echo -e "  ${options[$i]}"
            fi
        done
        echo
        echo -e "${GRAY}使用 ↑/↓ 键导航，Enter 确认，q 返回${RESET}"
        key=$(get_key)
        case $key in
            up)
                ((current--))
                if [ $current -lt 0 ]; then current=$((${#options[@]}-1)); fi
                ;;
            down)
                ((current++))
                if [ $current -ge ${#options[@]} ]; then current=0; fi
                ;;
            enter)
                return $current
                ;;
            quit)
                return 255
                ;;
        esac
    done
}

# 检查容器是否运行
is_container_running() {
    local container=$1
    local status=$(docker compose ps -q $container 2>/dev/null)
    if [[ -n "$status" ]]; then
        docker compose ps $container 2>/dev/null | grep -q "Up" && return 0
    fi
    return 1
}

# 获取容器退出码
get_container_exit_code() {
    local container=$1
    docker compose ps $container 2>/dev/null | grep -oP 'Exit \K\d+' || echo "N/A"
}

# 检查容器状态
check_container_status() {
    local containers=("broker" "rest_api" "postgres" "redis" "minio" "gpu_prove_agent0" "exec_agent0" "exec_agent1" "aux_agent" "snark_agent")
    local statuses=$(docker compose ps --format "table {{.Name}}\t{{.Status}}" 2>/dev/null)
    local has_issues=false
    for container in "${containers[@]}"; do
        if ! echo "$statuses" | grep -q "^$container.*Up"; then
            has_issues=true
            break
        fi
    done
    if [[ "$has_issues" == true ]]; then
        echo -e "${RED}${BOLD}⚠ 警告：部分容器未正常运行${RESET}"
        echo -e "${YELLOW}选择 '容器状态' 查看详情${RESET}\n"
    fi
}

# 显示容器状态
show_container_status() {
    clear
    echo -e "${BOLD}${CYAN}容器状态概览${RESET}"
    echo -e "${GRAY}════════════════════════════════════════${RESET}\n"
    local containers=$(docker compose ps --format "table {{.Name}}\t{{.Status}}\t{{.Service}}" 2>/dev/null | tail -n +2)
    if [[ -z "$containers" ]]; then
        echo -e "${RED}未找到容器，服务可能未启动${RESET}"
    else
        printf "%-30s %-20s %s\n" "容器" "状态" "服务"
        echo -e "${GRAY}────────────────────────────────────────────────────────────${RESET}"
        while IFS= read -r line; do
            local name=$(echo "$line" | awk '{print $1}')
            local status=$(echo "$line" | awk '{$1=""; print $0}' | sed 's/^ *//')
            local service=$(echo "$line" | awk '{print $NF}')
            if echo "$status" | grep -q "Up"; then
                printf "${GREEN}%-30s${RESET} %-20s %s\n" "$name" "✓ 运行中" "$service"
            elif echo "$status" | grep -q "Exit"; then
                printf "${RED}%-30s${RESET} ${RED}%-20s${RESET} %s\n" "$name" "✗ 已退出" "$service"
                if [[ "$service" == "broker" ]]; then
                    echo -e "${YELLOW}  └─ 最后错误：$(docker compose logs --tail=1 broker 2>&1 | grep -oE 'error:.*' | head -1)${RESET}"
                fi
            elif echo "$status" | grep -q "Restarting"; then
                printf "${YELLOW}%-30s${RESET} ${YELLOW}%-20s${RESET} %s\n" "$name" "↻ 重启中" "$service"
            else
                printf "%-30s %-20s %s\n" "$name" "$status" "$service"
            fi
        done <<< "$containers"
    fi
    echo -e "\n${GRAY}按任意键继续...${RESET}"
    read -n 1
}

# 分析 broker 错误
analyze_broker_errors() {
    local last_errors=$(docker compose logs --tail=100 broker 2>&1 | grep -i "error" | tail -5)
    if [[ -z "$last_errors" ]]; then
        return
    fi
    echo -e "\n${BOLD}${YELLOW}检测到问题：${RESET}"
    if echo "$last_errors" | grep -q "odd number of digits"; then
        echo -e "${RED}✗ 私钥格式无效${RESET}"
        echo -e "  ${YELLOW}→ 私钥应为 64 位十六进制字符（无 0x 前缀）${RESET}"
        echo -e "  ${YELLOW}→ 使用 '更改私钥' 选项修复${RESET}"
    fi
    if echo "$last_errors" | grep -q "connection refused"; then
        echo -e "${RED}✗ 连接被拒绝${RESET}"
        echo -e "  ${YELLOW}→ 检查所有必需服务是否运行${RESET}"
        echo -e "  ${YELLOW}→ 验证 RPC 地址是否可访问${RESET}"
    fi
    # 其他错误分析...
    echo -e "\n${GRAY}最后错误信息：${RESET}"
    echo "$last_errors" | while IFS= read -r line; do
        echo -e "${GRAY}  $line${RESET}"
    done
}

# 查看 broker 日志
view_broker_logs() {
    clear
    echo -e "${CYAN}${BOLD}Broker 日志${RESET}"
    echo -e "${GRAY}════════════════════════════════════════${RESET}\n"
    if is_container_running "broker"; then
        echo -e "${GREEN}Broker 运行中，显示实时日志（按 Ctrl+C 退出）...${RESET}\n"
        docker compose logs -f broker
    else
        echo -e "${RED}${BOLD}⚠ Broker 容器未运行！${RESET}"
        echo -e "${YELLOW}显示可用日志...${RESET}\n"
        docker compose logs broker 2>&1 || echo -e "${RED}无 broker 日志${RESET}"
        echo -e "\n${GRAY}────────────────────────────────────────${RESET}"
        analyze_broker_errors
    fi
}

# 查看最后 100 行 broker 日志
view_broker_logs_tail() {
    clear
    echo -e "${CYAN}${BOLD}最后 100 行 Broker 日志${RESET}"
    echo -e "${GRAY}════════════════════════════════════════${RESET}\n"
    if is_container_running "broker"; then
        echo -e "${GREEN}Broker 运行中，显示最后 100 行日志（按 Ctrl+C 退出）...${RESET}\n"
        docker compose logs --tail=100 -f broker
    else
        echo -e "${RED}${BOLD}⚠ Broker 容器未运行！${RESET}"
        echo -e "${YELLOW}显示最后 100 行日志...${RESET}\n"
        docker compose logs --tail=100 broker 2>&1 || echo -e "${RED}无 broker 日志${RESET}"
        echo -e "\n${GRAY}────────────────────────────────────────${RESET}"
        analyze_broker_errors
    fi
}

# 查看日志
view_logs() {
    echo -e "${BOLD}${CYAN}日志查看器${RESET}"
    echo -e "${GRAY}──────────────────${RESET}"
    check_container_status
    local options=("所有日志" "仅 Broker 日志" "最后 100 行 Broker 日志" "容器状态" "返回菜单")
    arrow_menu "${options[@]}"
    local choice=$?
    case $choice in
        0) clear; echo -e "${CYAN}${BOLD}显示所有日志（按 Ctrl+C 退出）...${RESET}\n"; just broker logs ;;
        1) view_broker_logs ;;
        2) view_broker_logs_tail ;;
        3) show_container_status ;;
        4|255) return ;;
    esac
}

# 启动 broker
start_broker() {
    clear
    echo -e "${CYAN}${BOLD}验证配置...${RESET}"
    if ! validate_config; then
        echo -e "\n${RED}配置验证失败！${RESET}"
        echo -e "${YELLOW}请修复上述问题后重试${RESET}"
        echo -e "\n按任意键返回菜单..."
        read -n 1
        return
    fi
    source .env.broker
    echo -e "${GREEN}✓ 配置验证通过${RESET}"
    echo -e "\n${GREEN}${BOLD}启动 broker...${RESET}"
    just broker
    sleep 3
    if ! is_container_running "broker"; then
        echo -e "\n${RED}${BOLD}⚠ Broker 启动失败！${RESET}"
        echo -e "${YELLOW}检查错误日志...${RESET}\n"
        docker compose logs --tail=20 broker
        analyze_broker_errors
        echo -e "\n按任意键返回菜单..."
        read -n 1
    fi
}

# 启动 bento
start_bento() {
    clear
    echo -e "${GREEN}${BOLD}为测试启动 bento...${RESET}"
    just bento
}

# 停止服务
stop_services() {
    clear
    echo -e "${YELLOW}${BOLD}停止服务...${RESET}"
    just broker down
    echo -e "\n${GREEN}服务已停止，按任意键继续...${RESET}"
    read -n 1
}

# 备份配置
backup_config() {
    clear
    local backup_dir="$INSTALL_DIR/backup-$(date +%Y%m%d-%H%M%S)"
    mkdir -p "$backup_dir"
    cp "$INSTALL_DIR/.env."* "$INSTALL_DIR/broker.toml" "$backup_dir" 2>/dev/null
    echo -e "${GREEN}配置文件已备份至 $backup_dir${RESET}"
    echo -e "\n按任意键继续..."
    read -n 1
}

# 更改网络
change_network() {
    echo -e "${BOLD}${YELLOW}网络选择${RESET}"
    echo -e "${GRAY}──────────────────${RESET}"
    local options=("Base 主网" "Base Sepolia 测试网" "Ethereum Sepolia 测试网" "返回菜单")
    arrow_menu "${options[@]}"
    local choice=$?
    if [[ -f .env.broker ]]; then
        source .env.broker
        CURRENT_SEGMENT_SIZE=$SEGMENT_SIZE
    fi
    case $choice in
        0)
            cp .env.base .env.broker
            echo -e "${GREEN}网络已更改为 Base 主网${RESET}"
            local selected_network="base"
            ;;
        1)
            cp .env.base-sepolia .env.broker
            echo -e "${GREEN}网络已更改为 Base Sepolia${RESET}"
            local selected_network="base-sepolia"
            ;;
        2)
            cp .env.eth-sepolia .env.broker
            echo -e "${GREEN}网络已更改为 Ethereum Sepolia${RESET}"
            local selected_network="eth-sepolia"
            ;;
        3|255) return ;;
    esac
    if [[ $choice -le 2 ]]; then
        if [[ -n "$CURRENT_SEGMENT_SIZE" ]]; then
            sed -i "s/export SEGMENT_SIZE=.*/export SEGMENT_SIZE=$CURRENT_SEGMENT_SIZE/" .env.broker
            sed -i "s/export SEGMENT_SIZE=.*/export SEGMENT_SIZE=$CURRENT_SEGMENT_SIZE/" .env.$selected_network
        fi
        echo -e "\n${BOLD}新网络的 RPC 配置：${RESET}"
        echo "推荐提供商："
        echo "- BlockPi（Base 网络免费）"
        echo "- Alchemy"
        echo "- Chainstack（设置 lookback_blocks=0）"
        read -p "请输入 RPC 地址： " new_rpc
        if [[ -n "$new_rpc" ]]; then
            sed -i "s|export RPC_URL=.*|export RPC_URL=\"$new_rpc\"|" .env.broker
            sed -i "s|export RPC_URL=.*|export RPC_URL=\"$new_rpc\"|" .env.$selected_network
            echo -e "${GREEN}RPC 地址已更新${RESET}"
        fi
        echo -e "${YELLOW}请重启 broker 以应用更改${RESET}"
        echo -e "\n按任意键继续..."
        read -n 1
    fi
}

# 更改私钥
change_private_key() {
    clear
    echo -e "${BOLD}${YELLOW}更改私钥${RESET}"
    echo -e "${GRAY}──────────────────${RESET}"
    echo -e "${RED}警告：这将更新所有网络文件的私钥${RESET}"
    read -sp "请输入新私钥（无 0x 前缀）： " new_key
    echo
    if [[ -z "$new_key" ]]; then
        echo -e "${RED}私钥不能为空，操作取消${RESET}"
        echo -e "\n按任意键继续..."
        read -n 1
        return
    fi
    if [[ ! "$new_key" =~ ^[0-9a-fA-F]{64}$ ]]; then
        echo -e "${RED}私钥格式无效！${RESET}"
        echo -e "${YELLOW}私钥必须为 64 位十六进制字符（无 0x 前缀）${RESET}"
        echo -e "\n按任意键继续..."
        read -n 1
        return
    fi
    for env_file in .env.broker .env.base .env.base-sepolia .env.eth-sepolia; do
        if [[ -f "$env_file" ]]; then
            sed -i "s/export PRIVATE_KEY=.*/export PRIVATE_KEY=$new_key/" "$env_file"
        fi
    done
    echo -e "\n${GREEN}私钥已成功更新${RESET}"
    echo -e "${YELLOW}请重启服务以应用更改${RESET}"
    echo -e "\n按任意键继续..."
    read -n 1
}

# 编辑 broker 配置
edit_broker_config() {
    clear
    nano broker.toml
}

# 存入质押
deposit_stake() {
    clear
    source .env.broker
    echo -e "${BOLD}${PURPLE}存入 USDC 质押${RESET}"
    echo -e "${GRAY}──────────────────${RESET}"
    read -p "请输入质押金额（USDC）： " amount
    if [[ -n "$amount" ]]; then
        boundless account deposit-stake "$amount"
        echo -e "\n按任意键继续..."
        read -n 1
    fi
}

# 检查质押余额
check_balance() {
    clear
    source .env.broker
    echo -e "${BOLD}${PURPLE}质押余额${RESET}"
    echo -e "${GRAY}──────────────────${RESET}"
    boundless account stake-balance
    echo -e "\n按任意键继续..."
    read -n 1
}

# 运行基准测试
run_benchmark_orders() {
    clear
    source .env.broker
    echo -e "${BOLD}${ORANGE}订单 ID 基准测试${RESET}"
    echo -e "${GRAY}──────────────────${RESET}"
    echo "从 https://explorer.beboundless.xyz/orders 获取订单 ID"
    read -p "订单 ID（逗号分隔）： " ids
    if [[ -n "$ids" ]]; then
        boundless proving benchmark --request-ids "$ids"
        echo -e "\n按任意键继续..."
        read -n 1
    fi
}

# 监控 GPU
monitor_gpus() {
    clear
    nvtop
}

# 检查更新
check_updates() {
    clear
    echo -e "${BOLD}${CYAN}检查更新${RESET}"
    echo -e "${GRAY}════════════════════════════════════════${RESET}\n"
    cd "$INSTALL_DIR"
    info "检查仓库更新..."
    git fetch origin release-0.10 >> "$LOG_FILE" 2>&1
    local local_commit
    local_commit=$(git rev-parse HEAD)
    local remote_commit
    remote_commit=$(git rev-parse origin/release-0.10)
    if [[ "$local_commit" != "$remote_commit" ]]; then
        echo -e "${YELLOW}Boundless 仓库有可用更新${RESET}"
        echo -e "${GRAY}运行 'git pull origin release-0.10' 更新${RESET}"
    else
        echo -e "${GREEN}✓ 仓库已是最新${RESET}"
    fi
    echo -e "\n${GRAY}按任意键继续...${RESET}"
    read -n 1
}

# 健康检查
health_check() {
    clear
    echo -e "${BOLD}${CYAN}系统健康检查${RESET}"
    echo -e "${GRAY}════════════════════════════════════════${RESET}\n"
    echo -e "${BOLD}1. 配置状态：${RESET}"
    if validate_config > /dev/null 2>&1; then
        echo -e "   ${GREEN}✓ 配置有效${RESET}"
        source .env.broker
        echo -e "   ${GRAY}网络：$(grep ORDER_STREAM_URL .env.broker | cut -d'/' -f3 | cut -d'.' -f1)${RESET}"
        echo -e "   ${GRAY}钱包：${PRIVATE_KEY:0:6}...${PRIVATE_KEY: -4}${RESET}"
    else
        echo -e "   ${RED}✗ 检测到配置问题${RESET}"
        validate_config
    fi
    echo -e "\n${BOLD}2. 服务状态：${RESET}"
    local critical_services=("broker" "rest_api" "postgres" "redis" "minio")
    local all_healthy=true
    for service in "${critical_services[@]}"; do
        if is_container_running "$service"; then
            echo -e "   ${GREEN}✓ $service${RESET}"
        else
            echo -e "   ${RED}✗ $service${RESET}"
            all_healthy=false
        fi
    done
    echo -e "\n${BOLD}3. GPU 状态：${RESET}"
    if command -v nvidia-smi > /dev/null 2>&1; then
        local gpu_count=$(nvidia-smi -L 2>/dev/null | wc -l)
        if [[ $gpu_count -gt 0 ]]; then
            echo -e "   ${GREEN}✓ 检测到 $gpu_count 个 GPU${RESET}"
            nvidia-smi --query-gpu=index,name,utilization.gpu,memory.used,memory.total --format=csv,noheader,nounits 2>/dev/null | while IFS=',' read -r idx name util mem_used mem_total; do
                echo -e "   ${GRAY}GPU $idx: $name - ${util}% 使用率, ${mem_used}MB/${mem_total}MB${RESET}"
            done
        else
            echo -e "   ${RED}✗ 未检测到 GPU${RESET}"
        fi
    else
        echo -e "   ${RED}✗ 未找到 nvidia-smi${RESET}"
    fi
    echo -e "\n${BOLD}4. 磁盘使用：${RESET}"
    local disk_usage
    disk_usage=$(df -h "$INSTALL_DIR" | tail -1 | awk '{print $5}')
    if [[ ${disk_usage%?} -gt 90 ]]; then
        echo -e "   ${RED}✗ 磁盘使用率高：$disk_usage${RESET}"
    else
        echo -e "   ${GREEN}✓ 磁盘使用率：$disk_usage${RESET}"
    fi
    echo -e "\n${BOLD}5. 内存使用：${RESET}"
    local mem_info
    mem_info=$(free -h | grep Mem)
    local mem_used
    mem_used=$(echo "$mem_info" | awk '{print $3}')
    local mem_total
    mem_total=$(echo "$mem_info" | awk '{print $2}')
    echo -e "   ${GREEN}✓ 内存使用：$mem_used/$mem_total${RESET}"
    echo -e "\n${BOLD}6. 网络状态：${RESET}"
    if [[ -n "$RPC_URL" ]]; then
        echo -e "   ${GRAY}测试 RPC 连接...${RESET}"
        local start_time
        start_time=$(date +%s)
        if curl -s -X POST "$RPC_URL" \
            -H "Content-Type: application/json" \
            -d '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}' \
            --connect-timeout 5 > /dev/null 2>&1; then
            local end_time
            end_time=$(date +%s)
            local latency=$((end_time - start_time))
            echo -e "   ${GREEN}✓ RPC 连接成功（延迟：${latency}秒）${RESET}"
        else
            echo -e "   ${RED}✗ RPC 连接失败${RESET}"
        fi
    else
        echo -e "   ${RED}✗ 未配置 RPC 地址${RESET}"
    fi
    echo -e "\n${BOLD}7. 总体状态：${RESET}"
    if [[ "$all_healthy" == true ]] && validate_config > /dev/null 2>&1 && [[ ${disk_usage%?} -le 90 ]]; then
        echo -e "   ${GREEN}✓ 系统健康且就绪${RESET}"
    else
        echo -e "   ${YELLOW}⚠ 检测到问题，请查看详情${RESET}"
    fi
    echo -e "\n${GRAY}按任意键继续...${RESET}"
    read -n 1
}

# 主菜单循环
current=0
menu_count=0
for item in "${menu_items[@]}"; do
    if [[ ! $item == *":"* ]]; then
        ((menu_count++))
    fi
done

while true; do
    draw_menu $current
    key=$(get_key)
    case $key in
        up)
            ((current--))
            if [ $current -lt 0 ]; then current=$((menu_count-1)); fi
            ;;
        down)
            ((current++))
            if [ $current -ge $menu_count ]; then current=0; fi
            ;;
        enter)
            selected=$(get_menu_item $current)
            case "$selected" in
                "启动 Broker") start_broker ;;
                "启动 Bento（仅测试）") start_bento ;;
                "停止服务") stop_services ;;
                "查看日志") view_logs ;;
                "健康检查") health_check ;;
                "备份配置文件") backup_config ;;
                "更改网络") change_network ;;
                "更改私钥") change_private_key ;;
                "编辑 Broker 配置") edit_broker_config ;;
                "存入质押") deposit_stake ;;
                "检查质押余额") check_balance ;;
                "运行基准测试（订单 ID）") run_benchmark_orders ;;
                "监控 GPU") monitor_gpus ;;
                "检查更新") check_updates ;;
                "退出")
                    clear
                    echo -e "${GREEN}再见！${RESET}"
                    exit 0
                    ;;
            esac
            ;;
        quit)
            clear
            echo -e "${GREEN}再见！${RESET}"
            exit 0
            ;;
    esac
done
EOF
    chmod +x "$INSTALL_DIR/prover.sh"
    success "管理脚本已创建于 $INSTALL_DIR/prover.sh"
}

# 设置日志轮转
setup_log_rotation() {
    info "设置日志轮转..."
    cat > /etc/logrotate.d/boundless_prover << EOF
$LOG_FILE $ERROR_LOG {
    size 10M
    rotate 5
    compress
    delaycompress
    missingok
    notifempty
    create 600 $(logname 2>/dev/null || echo "$USER") $(logname 2>/dev/null || echo "$USER")
}
EOF
    success "日志轮转已配置"
}

# 解析命令行参数
parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --allow-root)
                ALLOW_ROOT=true
                shift
                ;;
            --force-reclone)
                FORCE_RECLONE=true
                shift
                ;;
            --start-immediately)
                START_IMMEDIATELY=true
                shift
                ;;
            --non-interactive)
                NON_INTERACTIVE=true
                shift
                ;;
            --rpc-url=*)
                RPC_URL="${1#*=}"
                shift
                ;;
            --private-key=*)
                PRIVATE_KEY="${1#*=}"
                shift
                ;;
            --help)
                echo "用法：$0 [选项]"
                echo "选项："
                echo "  --allow-root        允许以 root 身份运行"
                echo "  --force-reclone     强制删除并重新克隆目录"
                echo "  --start-immediately 自动运行管理脚本"
                echo "  --non-interactive   非交互模式"
                echo "  --rpc-url=<url>     指定 RPC 地址"
                echo "  --private-key=<key> 指定私钥"
                echo "  --help              显示帮助信息"
                exit 0
                ;;
            *)
                echo "未知选项：$1"
                exit 1
                ;;
        esac
    done
}

# 清理退出
cleanup_on_exit() {
    local exit_code=$?
    if [ $exit_code -ne 0 ]; then
        error "安装失败，退出码：$exit_code"
        echo "[退出] 脚本退出，代码：$exit_code，时间：$(date)" >> "$ERROR_LOG"
        echo "[退出] 最后命令：${BASH_COMMAND}" >> "$ERROR_LOG"
        echo "[退出] 行号：${BASH_LINENO[0]}" >> "$ERROR_LOG"
        echo "[退出] 函数栈：${FUNCNAME[@]}" >> "$ERROR_LOG"
        echo -e "\n${RED}${BOLD}安装失败！${RESET}"
        echo -e "${YELLOW}查看错误日志：$ERROR_LOG${RESET}"
        echo -e "${YELLOW}查看完整日志：$LOG_FILE${RESET}"
        case $exit_code in
            $EXIT_DPKG_ERROR)
                echo -e "\n${RED}检测到 DPKG 配置错误！${RESET}"
                echo -e "${YELLOW}请手动运行以下命令：${RESET}"
                echo -e "${BOLD}dpkg --configure -a${RESET}"
                ;;
            $EXIT_OS_CHECK_FAILED)
                echo -e "\n${RED}操作系统检查失败！${RESET}"
                ;;
            $EXIT_DEPENDENCY_FAILED)
                echo -e "\n${RED}依赖安装失败！${RESET}"
                ;;
            $EXIT_GPU_ERROR)
                echo -e "\n${RED}GPU 配置错误！${RESET}"
                ;;
            $EXIT_NETWORK_ERROR)
                echo -e "\n${RED}网络配置错误！${RESET}"
                ;;
            $EXIT_USER_ABORT)
                echo -e "\n${YELLOW}用户取消安装${RESET}"
                ;;
            *)
                echo -e "\n${RED}未知错误！${RESET}"
                ;;
        esac
    fi
}

# 主函数
main() {
    trap cleanup_on_exit EXIT
    trap 'echo "[信号] 捕获信号 ${?}，行号：${LINENO}" >> "$ERROR_LOG"' ERR
    echo -e "${BOLD}${CYAN}Boundless Prover Node 安装脚本 by zakehowell (v$SCRIPT_VERSION)${RESET}"
    echo "========================================"
    mkdir -p "$(dirname "$LOG_FILE")"
    touch "$LOG_FILE"
    touch "$ERROR_LOG"
    echo "[开始] 安装开始，时间：$(date)" >> "$LOG_FILE"
    echo "[开始] 安装开始，时间：$(date)" >> "$ERROR_LOG"
    info "日志保存位置："
    info "  - 完整日志：cat $LOG_FILE"
    info "  - 错误日志：cat $ERROR_LOG"
    echo
    parse_args "$@"
    if [[ $EUID -eq 0 ]]; then
        if [[ "$ALLOW_ROOT" == "true" ]]; then
            warning "以 root 身份运行（通过 --allow-root 允许）"
        else
            warning "以 root 身份运行"
            prompt "是否继续？(y/N): "
            read -r response
            if [[ ! "$response" =~ ^[yY]$ ]]; then
                exit $EXIT_USER_ABORT
            fi
        fi
    else
        warning "本脚本需要 root 权限或适当权限的用户"
        info "请确保有安装软件包和修改系统设置的权限"
    fi
    check_disk_space
    check_os
    update_system
    info "安装所有依赖..."
    install_basic_deps
    install_docker
    install_nvidia_toolkit
    install_rust
    install_just
    install_rust_deps
    clone_repository
    detect_gpus
    configure_compose
    configure_network
    configure_broker
    create_management_script
    create_readme
    setup_log_rotation
    echo -e "\n${GREEN}${BOLD}安装完成！${RESET}"
    echo "[成功] 安装成功完成，时间：$(date)" >> "$LOG_FILE"
    echo -e "\n${BOLD}后续步骤：${RESET}"
    echo "1. 使用管理脚本管理节点："
    echo "2. 进入目录：cd $INSTALL_DIR"
    echo "3. 运行管理脚本：./prover.sh"
    echo "4. 使用管理脚本存入 USDC 质押"
    echo -e "\n${YELLOW}重要提示：${RESET} 启动时始终检查日志！"
    echo "GPU 监控：nvtop"
    echo "系统监控：htop"
    echo -e "\n${CYAN}安装日志保存位置：${RESET}"
    echo "  - $LOG_FILE"
    echo "  - $ERROR_LOG"
    echo -e "\n${YELLOW}安全提示：${RESET}"
    echo "私钥存储在 $INSTALL_DIR/.env.* 文件中。"
    echo "请确保这些文件不被未授权用户访问（当前权限为 600）。"
    if [[ "$START_IMMEDIATELY" == "true" ]]; then
        cd "$INSTALL_DIR"
        ./prover.sh
    elif [[ "$NON_INTERACTIVE" != "true" ]]; then
        prompt "现在进入管理脚本？(y/N): "
        read -r start_now
        if [[ "$start_now" =~ ^[yY]$ ]]; then
            cd "$INSTALL_DIR"
            ./prover.sh
        fi
    fi
}

# 运行主函数
main "$@"