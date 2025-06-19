# Boundless Prover 节点安装脚本

本脚本用于在 Ubuntu 系统（20.04/22.04）上自动安装和配置 Boundless Prover 节点。它会安装依赖、克隆 Boundless 仓库、配置 GPU，并生成管理脚本以运行节点。

## 前置要求
- **操作系统**：Ubuntu 20.04 或 22.04
- **硬件**：NVIDIA GPU，至少 8GB 显存（建议 12GB 以上）
- **权限**：Root 或 sudo 权限
- **网络**：稳定的互联网连接，支持 `eth_newBlockFilter` 的 RPC URL（如 Alchemy、BlockPi）
- **钱包**：用于质押 USDC 和与网络交互的私钥

## 一键安装
使用以下命令一键安装：
```bash
curl -sSL https://raw.githubusercontent.com/zakehowell/boundless/main/setup_boundless_prover.sh | bash