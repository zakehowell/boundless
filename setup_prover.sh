#!/bin/bash

# =============================================================================
# 无界证明者节点安装脚本
# 功能：自动化配置和安装无界证明者节点
# =============================================================================

set -euo pipefail

# 颜色定义
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
GREEN='\033[0;32m'
PURPLE='\033[0;35m'
BOLD='\033[1m'
RESET='\033[0m'

# 常量
SCRIPT_NAME="$(basename "$0")"
LOG_PATH="/var/log/prover_install.log"
ERROR_LOG_PATH="/var/log/prover_error.log"
WORK_DIR="$HOME/prover_node"
DOCKER_COMPOSE_FILE="$WORK_DIR/docker-compose.yml"
CONFIG_FILE="$WORK_DIR/config.toml"

# 退出状态码
SUCCESS=0
OS_ERROR=1
PKG_ERROR=2
DEP_ERROR=3
GPU_ERROR=4
NET_ERROR=5
USER_CANCEL=6
UNKNOWN_ERROR=99

# 标志变量
RUN_AS_ROOT=false
FORCE_REINSTALL=false
AUTO_START=false

# 解析命令行参数
parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --root-allowed)
                RUN_AS_ROOT=true
                shift
                ;;
            --force-reinstall)
                FORCE_REINSTALL=true
                shift
                ;;
            --auto-start)
                AUTO_START=true
                shift
                ;;
            --help)
                echo "使用方法: $0 [选项]"
                echo "选项:"
                echo "  --root-allowed      允许以 root 身份运行"
                echo "  --force-reinstall   强制删除并重新安装"
                echo "  --auto-start        安装后自动启动"
                echo "  --help              显示帮助信息"
                exit 0
                ;;
            *)
                echo "无效选项: $1"
                exit 1
                ;;
        esac
    done
}

# 日志记录函数
log_info() {
    printf "${BLUE}[信息]${RESET} %s\n" "$1"
    echo "[信息] $(date '+%Y-%m-%d %H:%M:%S') - $1" >> "$LOG_PATH"
}

log_success() {
    printf "${GREEN}[成功]${RESET} %s\n" "$1"
    echo "[成功] $(date '+%Y-%m-%d %H:%M:%S') - $1" >> "$LOG_PATH"
}

log_error() {
    printf "${RED}[错误]${RESET} %s\n" "$1" >&2
    echo "[错误] $(date '+%Y-%m-%d %H:%M:%S') - $1" >> "$LOG_PATH"
    echo "[错误] $(date '+%Y-%m-%d %H:%M:%S') - $1" >> "$ERROR_LOG_PATH"
}

log_warning() {
    printf "${YELLOW}[警告]${RESET} %s\n" "$1"
    echo "[警告] $(date '+%Y-%m-%d %H:%M:%S') - $1" >> "$LOG_PATH"
}

prompt_input() {
    printf "${PURPLE}[输入]${RESET} %s" "$1"
}

# 清理退出处理
handle_exit() {
    local exit_code=$?
    if [ $exit_code -ne 0 ]; then
        log_error "安装失败，退出码: $exit_code"
        echo "[退出] 退出时间: $(date)" >> "$ERROR_LOG_PATH"
        echo "[退出] 命令: ${BASH_COMMAND}" >> "$ERROR_LOG_PATH"
        echo "[退出] 行号: ${BASH_LINENO[0]}" >> "$ERROR_LOG_PATH"

        echo -e "\n${RED}${BOLD}安装失败！${RESET}"
        echo -e "${YELLOW}错误日志: $ERROR_LOG_PATH${RESET}"
        echo -e "${YELLOW}完整日志: $LOG_PATH${RESET}"

        case $exit_code in
            $PKG_ERROR)
                echo -e "\n${RED}包配置错误！${RESET}"
                echo -e "${YELLOW}请运行: ${BOLD}dpkg --configure -a${RESET}"
                ;;
            $OS_ERROR)
                echo -e "\n${RED}操作系统不兼容！${RESET}"
                ;;
            $DEP_ERROR)
                echo -e "\n${RED}依赖安装失败！${RESET}"
                ;;
            $GPU_ERROR)
                echo -e "\n${RED}GPU 配置错误！${RESET}"
                ;;
            $NET_ERROR)
                echo -e "\n${RED}网络配置错误！${RESET}"
                ;;
            $USER_CANCEL)
                echo -e "\n${YELLOW}用户取消安装。${RESET}"
                ;;
            *)
                echo -e "\n${RED}未知错误！${RESET}"
                ;;
        esac
    fi
}

trap handle_exit EXIT
trap 'echo "[信号] 捕获信号 ${?}，行号 ${LINENO}" >> "$ERROR_LOG_PATH"' ERR

# 网络配置
declare -A NETWORK_CONFIG
NETWORK_CONFIG["mainnet"]="主网|0x0b144e07a0826182b6b59788c34b32bfa86fb711|0x26759dbB201aFbA361Bec78E097Aa3942B0b4AB8|0x8C5a8b5cC272Fe2b74D18843CF9C3aCBc952a760|https://base-mainnet.beboundless.xyz"
NETWORK_CONFIG["base-test"]="Base 测试网|0x0b144e07a0826182b6b59788c34b32bfa86fb711|0x6B7ABa661041164b8dB98E30AE1454d2e9D5f14b|0x8C5a8b5cC272Fe2b74D18843CF9C3aCBc952a760|https://base-sepolia.beboundless.xyz"
NETWORK_CONFIG["eth-test"]="以太坊测试网|0x925d8331ddc0a1F0d96E68CF073DFE1d92b69187|0x13337C76fE2d1750246B68781ecEe164643b98Ec|0x7aAB646f23D1392d4522CFaB0b7FB5eaf6821d64|https://eth-sepolia.beboundless.xyz/"

# 检查包管理器状态
check_pkg_status() {
    if dpkg --audit 2>&1 | grep -q "dpkg was interrupted"; then
        log_error "包管理器中断，请手动修复"
        return 1
    fi
    return 0
}

# 验证操作系统
validate_os() {
    log_info "验证操作系统..."
    if [[ -f /etc/os-release ]]; then
        . /etc/os-release
        if [[ "${ID,,}" != "ubuntu" ]]; then
            log_error "不支持的系统: $NAME，仅支持 Ubuntu"
            exit $OS_ERROR
        elif [[ "${VERSION_ID,,}" != "22.04" && "${VERSION_ID,,}" != "20.04" ]]; then
            log_warning "推荐 Ubuntu 20.04/22.04，当前版本: $VERSION_ID"
            prompt_input "继续安装？(y/N): "
            read -r answer
            [[ ! "$answer" =~ ^[yY]$ ]] && exit $USER_CANCEL
        else
            log_info "系统版本: $PRETTY_NAME"
        fi
    else
        log_error "未找到系统信息文件"
        exit $OS_ERROR
    fi
}

# 检查命令是否存在
is_cmd_available() {
    command -v "$1" &> /dev/null
}

# 检查包是否安装
is_pkg_installed() {
    dpkg -s "$1" &> /dev/null
}

# 系统更新
system_update() {
    log_info "更新系统..."
    check_pkg_status || exit $PKG_ERROR
    {
        apt update -y || { log_error "更新失败"; exit $DEP_ERROR; }
        apt upgrade -y || { log_error "升级失败"; exit $DEP_ERROR; }
    } >> "$LOG_PATH" 2>&1
    log_success "系统更新完成"
}

# 安装基础依赖
install_base_deps() {
    local deps=(
        curl git wget jq make gcc nano tmux htop nvme-cli pkg-config
        libssl-dev tar clang unzip libleveldb-dev libclang-dev nvtop
        ubuntu-drivers-common gnupg ca-certificates lsb-release
        postgresql-client
    )
    log_info "安装基础依赖..."
    check_pkg_status || exit $PKG_ERROR
    {
        apt install -y "${deps[@]}" || { log_error "依赖安装失败"; exit $DEP_ERROR; }
    } >> "$LOG_PATH" 2>&1
    log_success "基础依赖安装完成"
}

# 安装 Docker
setup_docker() {
    is_cmd_available docker && { log_info "Docker 已安装"; return; }
    log_info "安装 Docker..."
    check_pkg_status || exit $PKG_ERROR
    {
        apt install -y apt-transport-https ca-certificates curl software-properties-common
        curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /usr/share/keyrings/docker-keyring.gpg
        echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/docker-keyring.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" | tee /etc/apt/sources.list.d/docker.list
        apt update -y
        apt install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin
        systemctl enable docker
        systemctl start docker
        usermod -aG docker "$USER"
    } >> "$LOG_PATH" 2>&1
    log_success "Docker 安装完成"
}

# 安装 NVIDIA 容器支持
setup_nvidia_docker() {
    is_pkg_installed nvidia-docker2 && { log_info "NVIDIA 容器支持已安装"; return; }
    log_info "安装 NVIDIA 容器支持..."
    check_pkg_status || exit $PKG_ERROR
    {
        distribution=$(grep '^ID=' /etc/os-release | cut -d'=' -f2 | tr -d '"')$(grep '^VERSION_ID=' /etc/os-release | cut -d'=' -f2 | tr -d '"')
        curl -s -L https://nvidia.github.io/nvidia-docker/gpgkey | apt-key add -
        curl -s -L https://nvidia.github.io/nvidia-docker/"$distribution"/nvidia-docker.list | tee /etc/apt/sources.list.d/nvidia-docker.list
        apt update -y
        apt install -y nvidia-docker2
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
    } >> "$LOG_PATH" 2>&1
    log_success "NVIDIA 容器支持安装完成"
}

# 安装 Rust 环境
setup_rust() {
    is_cmd_available rustc && { log_info "Rust 已安装"; return; }
    log_info "安装 Rust..."
    {
        curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y
        source "$HOME/.cargo/env"
        rustup update
    } >> "$LOG_PATH" 2>&1
    log_success "Rust 安装完成"
}

# 安装 Just 工具
setup_just() {
    is_cmd_available just && { log_info "Just 已安装"; return; }
    log_info "安装 Just..."
    {
        curl --proto '=https' --tlsv1.2 -sSf https://just.systems/install.sh | bash -s -- --to /usr/local/bin
    } >> "$LOG_PATH" 2>&1
    log_success "Just 安装完成"
}

# 安装 Rust 相关依赖
setup_rust_tools() {
    log_info "安装 Rust 工具..."
    source "$HOME/.cargo/env" || { log_error "无法加载 Rust 环境"; exit $DEP_ERROR; }
    {
        curl -L https://risczero.com/install | bash
        export PATH="$PATH:/root/.risc0/bin"
        rzup install rust
        TOOLCHAIN=$(rustup toolchain list | grep risc0 | head -1)
        [[ -z "$TOOLCHAIN" ]] && { log_error "未找到 RISC Zero 工具链"; exit $DEP_ERROR; }
        log_info "使用工具链: $TOOLCHAIN"
        cargo install cargo-risczero
        RUSTUP_TOOLCHAIN=$TOOLCHAIN cargo install --git https://github.com/risc0/risc0 bento-client --bin bento_cli
        cargo install --locked boundless-cli
        echo 'export PATH="$HOME/.cargo/bin:$PATH"' >> ~/.bashrc
        source ~/.bashrc
    } >> "$LOG_PATH" 2>&1
    log_success "Rust 工具安装完成"
}

# 克隆仓库
fetch_repo() {
    log_info "获取仓库..."
    if [[ -d "$WORK_DIR" ]]; then
        if [[ "$FORCE_REINSTALL" == "true" ]]; then
            log_warning "强制删除现有目录 $WORK_DIR"
            rm -rf "$WORK_DIR"
        else
            log_warning "目录 $WORK_DIR 已存在"
            prompt_input "删除并重新克隆？(y/N): "
            read -r answer
            if [[ "$answer" =~ ^[yY]$ ]]; then
                rm -rf "$WORK_DIR"
            else
                cd "$WORK_DIR"
                git pull origin release-0.10 >> "$LOG_PATH" 2>&1
                return
            fi
        fi
    fi
    {
        git clone https://github.com/boundless-xyz/boundless "$WORK_DIR"
        cd "$WORK_DIR"
        git checkout release-0.10
        git submodule update --init --recursive
    } >> "$LOG_PATH" 2>&1
    log_success "仓库克隆完成"
}

# 检测 GPU
check_gpus() {
    log_info "检查 GPU..."
    is_cmd_available nvidia-smi || { log_error "未找到 nvidia-smi"; exit $GPU_ERROR; }
    GPU_COUNT=$(nvidia-smi -L 2>/dev/null | wc -l)
    [[ $GPU_COUNT -eq 0 ]] && { log_error "未检测到 GPU"; exit $GPU_ERROR; }
    log_info "检测到 $GPU_COUNT 个 GPU"
    declare -a GPU_MEM
    for i in $(seq 0 $((GPU_COUNT - 1))); do
        MEM=$(nvidia-smi -i $i --query-gpu=memory.total --format=csv,noheader,nounits | tr -d ' ')
        [[ -z "$MEM" ]] && { log_error "无法获取 GPU $i 内存"; exit $GPU_ERROR; }
        GPU_MEM+=($MEM)
        log_info "GPU $i: ${MEM}MB"
    done
    MIN_VRAM=$(printf '%s\n' "${GPU_MEM[@]}" | sort -n | head -1)
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
    log_info "设置 SEGMENT_SIZE=$SEGMENT_SIZE (基于 ${MIN_VRAM}MB)"
}

# 配置 Docker Compose
setup_compose() {
    log_info "为 $GPU_COUNT 个 GPU 配置 Docker Compose..."
    if [[ $GPU_COUNT -eq 1 ]]; then
        log_info "单 GPU，无需额外配置"
        return
    fi
    cat > "$DOCKER_COMPOSE_FILE" << 'EOF'
name: prover
x-common-env: &common-env
  DATABASE_URL: postgresql://${POSTGRES_USER:-worker}:${POSTGRES_PASSWORD:-password}@${POSTGRES_HOST:-postgres}:${POSTGRES_PORT:-5432}/${POSTGRES_DB:-taskdb}
  REDIS_URL: redis://${REDIS_HOST:-redis}:6379
  S3_URL: http://${MINIO_HOST:-minio}:9000
  S3_BUCKET: ${MINIO_BUCKET:-workflow}
  S3_ACCESS_KEY: ${MINIO_ROOT_USER:-admin}
  S3_SECRET_KEY: ${MINIO_ROOT_PASS:-password}
  RUST_LOG: ${RUST_LOG:-info}
  RUST_BACKTRACE: 1

x-agent-base: &agent-base
  image: risczero/risc0-bento-agent:stable@sha256:c6fcc92686a5d4b20da963ebba3045f09a64695c9ba9a9aa984dd98b5ddbd6f9
  restart: always
  runtime: nvidia
  depends_on:
    - postgres
    - redis
    - minio
  environment:
    <<: *common-env

x-exec-agent: &exec-agent
  <<: *agent-base
  mem_limit: 4G
  cpus: 3
  environment:
    <<: *common-env
    RISC0_KECCAK_PO2: ${RISC0_KECCAK_PO2:-17}
  entrypoint: /app/agent -t exec --segment-po2 ${SEGMENT_SIZE:-21}

services:
  redis:
    hostname: ${REDIS_HOST:-redis}
    image: ${REDIS_IMG:-redis:7.2.5-alpine3.19}
    restart: always
    ports:
      - 6379:6379
    volumes:
      - redis-data:/data

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
      - config-data:/db
    depends_on:
      - postgres
      - redis
      - minio

  exec_agent_0:
    <<: *exec-agent

  exec_agent_1:
    <<: *exec-agent

  aux_agent:
    <<: *agent-base
    mem_limit: 256M
    cpus: 1
    entrypoint: /app/agent -t aux --monitor-requeue
EOF
    for i in $(seq 0 $((GPU_COUNT - 1))); do
        cat >> "$DOCKER_COMPOSE_FILE" << EOF
  prove_agent_$i:
    <<: *agent-base
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
    cat >> "$DOCKER_COMPOSE_FILE" << 'EOF'
  snark_agent:
    <<: *agent-base
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
      <<: *common-env
    ports:
      - '8081:8081'
    entrypoint: /app/rest_api --bind-addr 0.0.0.0:8081 --snark-timeout ${SNARK_TIMEOUT:-180}

  broker:
    restart: always
    depends_on:
      - rest_api
EOF
    for i in $(seq 0 $((GPU_COUNT - 1))); do
        echo "      - prove_agent_$i" >> "$DOCKER_COMPOSE_FILE"
    done
    cat >> "$DOCKER_COMPOSE_FILE" << 'EOF'
      - exec_agent_0
      - exec_agent_1
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
        source: ./config.toml
        target: /app/config.toml
      - config-data:/db/
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
    entrypoint: /app/broker --db-url 'sqlite:///db/broker.db' --set-verifier-address ${SET_VERIFIER_ADDRESS} --boundless-market-address ${BOUNDLESS_MARKET_ADDRESS} --config-file /app/config.toml --bento-api-url http://localhost:8081

volumes:
  redis-data:
  postgres-data:
  minio-data:
  grafana-data:
  config-data:
EOF
    log_success "Docker Compose 配置完成"
}

# 配置网络
setup_network() {
    log_info "设置网络..."
    echo -e "\n${BOLD}网络选项:${RESET}"
    echo "1) 主网"
    echo "2) Base 测试网"
    echo "3) 以太坊测试网"
    prompt_input "选择网络 (1-3): "
    read -r choice
    case $choice in
        1) NET="mainnet" ;;
        2) NET="base-test" ;;
        3) NET="eth-test" ;;
        *) log_error "无效网络选择"; exit $NET_ERROR ;;
    esac
    IFS='|' read -r NET_NAME V_ADDRESS M_ADDRESS S_ADDRESS STREAM_URL <<< "${NETWORK_CONFIG[$NET]}"
    log_info "选择网络: $NET_NAME"
    echo -e "\n${BOLD}RPC 设置:${RESET}"
    echo "需要支持 eth_newBlockFilter 的 RPC，推荐:"
    echo "- Alchemy（lookback_block=120）"
    echo "- BlockPi（Base 免费）"
    echo "- Chainstack（lookback_blocks=0）"
    prompt_input "输入 RPC URL: "
    read -r RPC
    [[ -z "$RPC" ]] && { log_error "RPC URL 不能为空"; exit $NET_ERROR; }
    prompt_input "输入私钥（无 0x 前缀）: "
    read -rs PRIV_KEY
    echo
    [[ -z "$PRIV_KEY" ]] && { log_error "私钥不能为空"; exit $NET_ERROR; }
    cat > "$WORK_DIR/config.env" << EOF
# 网络: $NET_NAME
export VERIFIER_ADDRESS=$V_ADDRESS
export MARKET_ADDRESS=$M_ADDRESS
export SET_ADDRESS=$S_ADDRESS
export STREAM_URL="$STREAM_URL"
export RPC_URL="$RPC"
export PRIVATE_KEY=$PRIV_KEY
export SEGMENT_SIZE=$SEGMENT_SIZE
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
    for net in mainnet base-test eth-test; do
        IFS='|' read -r _ V_ADDR M_ADDR S_ADDR S_URL <<< "${NETWORK_CONFIG[$net]}"
        cat > "$WORK_DIR/config.$net.env" << EOF
export VERIFIER_ADDRESS=$V_ADDR
export MARKET_ADDRESS=$M_ADDR
export SET_ADDRESS=$S_ADDR
export STREAM_URL="$S_URL"
export RPC_URL="$RPC"
export PRIVATE_KEY=$PRIV_KEY
export SEGMENT_SIZE=$SEGMENT_SIZE
EOF
    done
    chmod 600 "$WORK_DIR/config.env"
    chmod 600 "$WORK_DIR/config."*.env
    log_success "网络配置完成"
}

# 配置节点参数
setup_node_config() {
    log_info "设置节点参数..."
    cp "$WORK_DIR/broker-template.toml" "$CONFIG_FILE"
    echo -e "\n${BOLD}节点参数:${RESET}"
    prompt_input "每百万周期价格（默认: 0.0000005）: "
    read -r price
    price=${price:-0.0000005}
    prompt_input "最大证明速度（kHz，默认: 100）: "
    read -r speed
    speed=${speed:-100}
    prompt_input "最大周期数（百万，默认: 8000）: "
    read -r cycle_limit
    cycle_limit=${cycle_limit:-8000}
    prompt_input "最短截止时间（秒，默认: 300）: "
    read -r deadline
    deadline=${deadline:-300}
    prompt_input "最大并行证明数（默认: 2）: "
    read -r proofs
    proofs=${proofs:-2}
    prompt_input "锁定优先级 gas（Gwei，默认: 0）: "
    read -r gas
    sed -i "s/mcycle_price = \"[^\"]*\"/mcycle_price = \"$price\"/" "$CONFIG_FILE"
    sed -i "s/peak_prove_khz = [0-9]*/peak_prove_khz = $speed/" "$CONFIG_FILE"
    sed -i "s/max_mcycle_limit = [0-9]*/max_mcycle_limit = $cycle_limit/" "$CONFIG_FILE"
    sed -i "s/min_deadline = [0-9]*/min_deadline = $deadline/" "$CONFIG_FILE"
    sed -i "s/max_concurrent_proofs = [0-9]*/max_concurrent_proofs = $proofs/" "$CONFIG_FILE"
    [[ -n "$gas" ]] && sed -i "s/#lockin_priority_gas = [0-9]*/lockin_priority_gas = $gas/" "$CONFIG_FILE"
    log_success "节点参数配置完成"
}

# 创建控制脚本
create_control_script() {
    log_info "生成控制脚本..."
    cat > "$WORK_DIR/control.sh" << 'EOF'
#!/bin/bash

export PATH="$HOME/.cargo/bin:$PATH"

WORK_DIR="$(dirname "$0")"
cd "$WORK_DIR"

# 颜色定义
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
GREEN='\033[0;32m'
RED='\033[0;31m'
PURPLE='\033[0;35m'
GRAY='\033[0;90m'
BOLD='\033[1m'
RESET='\033[0m'

# 菜单选项
MENU_OPTIONS=(
    "服务管理:服务"
    "启动节点"
    "启动测试模式"
    "停止服务"
    "查看日志"
    "系统检查"
    "分隔符:"
    "配置管理:配置"
    "切换网络"
    "更新私钥"
    "编辑节点配置"
    "分隔符:"
    "质押管理:质押"
    "添加质押"
    "查询质押"
    "分隔符:"
    "性能测试:基准"
    "运行基准测试"
    "分隔符:"
    "监控管理:监控"
    "监控 GPU"
    "分隔符:"
    "退出"
)

# 显示菜单
show_menu() {
    local selected=$1
    clear
    echo -e "${BOLD}${BLUE}┌──────────────────────────────┐${RESET}"
    echo -e "${BOLD}${BLUE}│ 无界证明者控制面板         │${RESET}"
    echo -e "${BOLD}${BLUE}└──────────────────────────────┘${RESET}"
    echo
    local idx=0
    for opt in "${MENU_OPTIONS[@]}"; do
        if [[ $opt == *":"* ]]; then
            if [[ $opt == "分隔符:" ]]; then
                echo -e "${GRAY}──────────────────────────────${RESET}"
            else
                local cat=$(echo $opt | cut -d: -f1)
                local title=$(echo $opt | cut -d: -f2)
                case $cat in
                    "服务管理") echo -e "\n${BOLD}${GREEN}▶ $title${RESET}" ;;
                    "配置管理") echo -e "\n${BOLD}${YELLOW}▶ $title${RESET}" ;;
                    "质押管理") echo -e "\n${BOLD}${PURPLE}▶ $title${RESET}" ;;
                    "性能测试") echo -e "\n${BOLD}${BLUE}▶ $title${RESET}" ;;
                    "监控管理") echo -e "\n${BOLD}${BLUE}▶ $title${RESET}" ;;
                esac
            fi
        else
            if [ $idx -eq $selected ]; then
                echo -e "  ${BOLD}${BLUE}→ $opt${RESET}"
            else
                echo -e "    $opt"
            fi
            ((idx++))
        fi
    done
    echo -e "\n${GRAY}↑/↓ 导航，回车确认，q 退出${RESET}"
}

# 获取菜单项
get_menu_item() {
    local selected=$1
    local idx=0
    for opt in "${MENU_OPTIONS[@]}"; do
        if [[ ! $opt == *":"* ]]; then
            if [ $idx -eq $selected ]; then
                echo "$opt"
                return
            fi
            ((idx++))
        fi
    done
}

# 读取按键
read_key() {
    local key
    IFS= read -rsn1 key
    if [[ $key == "" ]]; then echo enter; fi
    if [[ $key == $'\x1b' ]]; then
        read -rsn2 key
        if [[ $key == [A ]]; then echo up; fi
        if [[ $key == [B ]]; then echo down; fi
    fi
    if [[ $key == "q" || $key == "Q" ]]; then echo quit; fi
}

# 验证配置
check_config() {
    local errors=0
    if [[ ! -f config.env ]]; then
        echo -e "${RED}✗ 未找到 config.env${RESET}"
        ((errors++))
    else
        source config.env
        [[ ! "$PRIVATE_KEY" =~ ^[0-9a-fA-F]{64}$ ]] && { echo -e "${RED}✗ 私钥无效${RESET}"; ((errors++)); }
        [[ -z "$RPC_URL" ]] && { echo -e "${RED}✗ RPC URL 为空${RESET}"; ((errors++)); }
        [[ -z "$MARKET_ADDRESS" || -z "$SET_ADDRESS" ]] && { echo -e "${RED}✗ 合约地址缺失${RESET}"; ((errors++)); }
    fi
    return $errors
}

# 子菜单导航
sub_menu() {
    local -a opts=("$@")
    local selected=0
    while true; do
        clear
        for i in "${!opts[@]}"; do
            if [ $i -eq $selected ]; then
                echo -e "${BOLD}${BLUE}→ ${opts[$i]}${RESET}"
            else
                echo -e "  ${opts[$i]}"
            fi
        done
        echo -e "\n${GRAY}↑/↓ 导航，回车确认，q 返回${RESET}"
        key=$(read_key)
        case $key in
            up) ((selected--)); [ $selected -lt 0 ] && selected=$((${#opts[@]}-1)) ;;
            down) ((selected++)); [ $selected -ge ${#opts[@]} ] && selected=0 ;;
            enter) return $selected ;;
            quit) return 255 ;;
        esac
    done
}

# 检查容器状态
is_container_active() {
    local container=$1
    docker compose ps -q $container 2>/dev/null | grep -q . && docker compose ps $container 2>/dev/null | grep -q "Up"
}

# 显示容器状态
show_containers() {
    clear
    echo -e "${BOLD}${BLUE}容器状态${RESET}\n${GRAY}──────────────────────────────${RESET}\n"
    local containers=$(docker compose ps --format "table {{.Name}}\t{{.Status}}\t{{.Service}}" 2>/dev/null | tail -n +2)
    if [[ -z "$containers" ]]; then
        echo -e "${RED}无容器运行${RESET}"
    else
        printf "%-30s %-20s %s\n" "容器" "状态" "服务"
        echo -e "${GRAY}──────────────────────────────────────────────${RESET}"
        while IFS= read -r line; do
            local name=$(echo "$line" | awk '{print $1}')
            local status=$(echo "$line" | awk '{$1=""; print $0}' | sed 's/^ *//')
            local service=$(echo "$line" | awk '{print $NF}')
            if echo "$status" | grep -q "Up"; then
                printf "${GREEN}%-30s${RESET} %-20s %s\n" "$name" "✓ 运行" "$service"
            elif echo "$status" | grep -q "Exit"; then
                printf "${RED}%-30s${RESET} ${RED}%-20s${RESET} %s\n" "$name" "✗ 停止" "$service"
            else
                printf "%-30s %-20s %s\n" "$name" "$status" "$service"
            fi
        done <<< "$containers"
    fi
    echo -e "\n${GRAY}按任意键继续...${RESET}"
    read -n 1
}

# 查看日志
view_logs() {
    clear
    echo -e "${BOLD}${BLUE}日志查看${RESET}\n${GRAY}──────────────────────────────${RESET}"
    local opts=("所有日志" "节点日志" "最后100行节点日志" "容器状态" "返回")
    sub_menu "${opts[@]}"
    case $? in
        0) clear; just broker logs ;;
        1) clear; docker compose logs -f broker ;;
        2) clear; docker compose logs --tail=100 -f broker ;;
        3) show_containers ;;
        4|255) return ;;
    esac
}

# 启动节点
start_node() {
    clear
    echo -e "${BOLD}${BLUE}启动节点${RESET}"
    check_config || { echo -e "${RED}配置无效${RESET}"; read -n 1; return; }
    just broker
    sleep 3
    is_container_active broker || { echo -e "${RED}节点启动失败${RESET}"; docker compose logs --tail=20 broker; read -n 1; }
}

# 停止服务
stop_node() {
    clear
    echo -e "${BOLD}${YELLOW}停止服务${RESET}"
    just broker down
    echo -e "\n${GREEN}服务已停止${RESET}"
    read -n 1
}

# 切换网络
switch_network() {
    clear
    echo -e "${BOLD}${YELLOW}切换网络${RESET}"
    local opts=("主网" "Base 测试网" "以太坊测试网" "返回")
    sub_menu "${opts[@]}"
    case $? in
        0) cp config.mainnet.env config.env; NET="mainnet" ;;
        1) cp config.base-test.env config.env; NET="base-test" ;;
        2) cp config.eth-test.env config.env; NET="eth-test" ;;
        3|255) return ;;
    esac
    if [[ $? -le 2 ]]; then
        source config.env
        echo -e "\n${BOLD}更新 RPC:${RESET}"
        read -p "输入新 RPC URL: " new_rpc
        if [[ -n "$new_rpc" ]]; then
            sed -i "s|export RPC_URL=.*|export RPC_URL=\"$new_rpc\"|" config.env
            sed -i "s|export RPC_URL=.*|export RPC_URL=\"$new_rpc\"|" config.$NET.env
        fi
        echo -e "${GREEN}网络切换完成${RESET}"
        read -n 1
    fi
}

# 更新私钥
update_key() {
    clear
    echo -e "${BOLD}${YELLOW}更新私钥${RESET}"
    read -sp "输入新私钥: " new_key
    echo
    if [[ ! "$new_key" =~ ^[0-9a-fA-F]{64}$ ]]; then
        echo -e "${RED}私钥无效${RESET}"
        read -n 1
        return
    fi
    for file in config.env config.*.env; do
        [[ -f "$file" ]] && sed -i "s/export PRIVATE_KEY=.*/export PRIVATE_KEY=$new_key/" "$file"
    done
    echo -e "${GREEN}私钥更新完成${RESET}"
    read -n 1
}

# 编辑配置
edit_config() {
    clear
    nano config.toml
}

# 添加质押
add_stake() {
    clear
    source config.env
    echo -e "${BOLD}${PURPLE}添加质押${RESET}"
    read -p "输入 USDC 金额: " amount
    [[ -n "$amount" ]] && boundless account deposit-stake "$amount"
    read -n 1
}

# 查询质押
check_stake() {
    clear
    source config.env
    echo -e "${BOLD}${PURPLE}查询质押${RESET}"
    boundless account stake-balance
    read -n 1
}

# 运行基准测试
run_benchmark() {
    clear
    source config.env
    echo -e "${BOLD}${BLUE}基准测试${RESET}"
    read -p "输入订单 ID（逗号分隔）: " ids
    [[ -n "$ids" ]] && boundless proving benchmark --request-ids "$ids"
    read -n 1
}

# 监控 GPU
monitor_gpu() {
    clear
    nvtop
}

# 系统检查
system_check() {
    clear
    echo -e "${BOLD}${BLUE}系统检查${RESET}\n${GRAY}──────────────────────────────${RESET}"
    echo -e "${BOLD}配置:${RESET}"
    if check_config > /dev/null 2>&1; then
        echo -e "${GREEN}✓ 配置有效${RESET}"
    else
        echo -e "${RED}✗ 配置错误${RESET}"
        check_config
    fi
    echo -e "\n${BOLD}服务:${RESET}"
    for svc in broker rest_api postgres redis minio; do
        is_container_active $svc && echo -e "${GREEN}✓ $svc${RESET}" || echo -e "${RED}✗ $svc${RESET}"
    done
    echo -e "\n${BOLD}GPU:${RESET}"
    if nvidia-smi -L > /dev/null 2>&1; then
        echo -e "${GREEN}✓ $(nvidia-smi -L | wc -l) 个 GPU${RESET}"
    else
        echo -e "${RED}✗ GPU 未检测到${RESET}"
    fi
    read -n 1
}

# 主循环
current=0
menu_count=$(grep -v ":" <<< "${MENU_OPTIONS[*]}" | wc -l)
while true; do
    show_menu $current
    key=$(read_key)
    case $key in
        up) ((current--)); [ $current -lt 0 ] && current=$((menu_count-1)) ;;
        down) ((current++)); [ $current -ge $menu_count ] && current=0 ;;
        enter)
            case $(get_menu_item $current) in
                "启动节点") start_node ;;
                "启动测试模式") just bento ;;
                "停止服务") stop_node ;;
                "查看日志") view_logs ;;
                "系统检查") system_check ;;
                "切换网络") switch_network ;;
                "更新私钥") update_key ;;
                "编辑节点配置") edit_config ;;
                "添加质押") add_stake ;;
                "查询质押") check_stake ;;
                "运行基准测试") run_benchmark ;;
                "监控 GPU") monitor_gpu ;;
                "退出") clear; echo -e "${GREEN}退出${RESET}"; exit 0 ;;
            esac
            ;;
        quit) clear; echo -e "${GREEN}退出${RESET}"; exit 0 ;;
    esac
done
EOF
    chmod +x "$WORK_DIR/control.sh"
    log_success "控制脚本生成完成"
}

# 主安装流程
main_install() {
    echo -e "${BOLD}${BLUE}无界证明者节点安装${RESET}\n=============================="
    mkdir -p "$(dirname "$LOG_PATH")"
    touch "$LOG_PATH" "$ERROR_LOG_PATH"
    echo "[开始] $(date)" >> "$LOG_PATH"
    echo "[开始] $(date)" >> "$ERROR_LOG_PATH"
    log_info "日志文件: $LOG_PATH"
    log_info "错误日志: $ERROR_LOG_PATH"
    if [[ $EUID -eq 0 ]]; then
        if [[ "$RUN_AS_ROOT" == "true" ]]; then
            log_warning "以 root 运行（已允许）"
        else
            log_warning "以 root 运行"
            prompt_input "继续？(y/N): "
            read -r answer
            [[ ! "$answer" =~ ^[yY]$ ]] && exit $USER_CANCEL
        fi
    fi
    parse_args "$@"
    validate_os
    system_update
    install_base_deps
    setup_docker
    setup_nvidia_docker
    setup_rust
    setup_just
    setup_rust_tools
    fetch_repo
    check_gpus
    setup_compose
    setup_network
    setup_node_config
    create_control_script
    echo -e "\n${GREEN}${BOLD}安装成功！${RESET}"
    echo -e "\n${BOLD}下一步:${RESET}"
    echo "1. 进入目录: cd $WORK_DIR"
    echo "2. 运行控制脚本: ./control.sh"
    echo "3. 通过控制脚本管理节点"
    echo -e "\n${YELLOW}注意:${RESET} 定期检查日志！"
    echo "GPU 监控: nvtop"
    echo "系统监控: htop"
}

main_install "$@"