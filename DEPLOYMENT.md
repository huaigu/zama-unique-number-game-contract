# UniqueNumberGameFactory Sepolia Deployment Guide

本指南介绍如何将 UniqueNumberGameFactory 合约部署到 Sepolia 测试网。

## 📋 前置条件

### 1. 环境变量设置

首先设置必要的环境变量：

```bash
# 设置 Hardhat 变量
npx hardhat vars setup

# 你需要设置以下变量：
# MNEMONIC - 你的钱包助记词
# INFURA_API_KEY - Infura API 密钥
# ETHERSCAN_API_KEY - Etherscan API 密钥（用于合约验证）
```

### 2. Sepolia ETH

确保你的钱包有足够的 Sepolia ETH：
- 获取方式: [Sepolia Faucet](https://sepoliafaucet.com/)
- 部署大约需要: 0.01-0.02 ETH

### 3. API 密钥

- **Infura**: 在 [Infura](https://infura.io/) 获取免费 API 密钥
- **Etherscan**: 在 [Etherscan](https://etherscan.io/apis) 获取免费 API 密钥

## 🚀 部署步骤

### 1. 编译合约

```bash
# 清理并专门为 Sepolia 编译
npx hardhat clean
npx hardhat compile --network sepolia
```

### 2. 部署到 Sepolia

```bash
# 部署 UniqueNumberGameFactory
npx hardhat deploy --network sepolia --tags UniqueNumberGameFactory

# 或者运行特定的部署脚本
npx hardhat deploy --network sepolia deploy/deploy-game.ts
```

部署脚本将自动：
- 部署合约到 Sepolia
- 等待 5 个区块确认
- 验证合约到 Etherscan
- 检查 FHEVM 兼容性
- 显示部署摘要

### 3. 验证部署

检查部署是否成功：

```bash
# 获取合约地址
npx hardhat game:address --network sepolia

# 检查 FHEVM 兼容性
npx hardhat fhevm:check-fhevm-compatibility --network sepolia --address <合约地址>
```

## 🎮 与合约交互

### 查看可用任务

```bash
npx hardhat --network sepolia --help
```

### 基本操作

```bash
# 1. 创建新游戏
npx hardhat game:create \
  --min 1 \
  --max 10 \
  --players 3 \
  --fee "0.01" \
  --duration 3600 \
  --network sepolia

# 2. 查看游戏信息
npx hardhat game:info --id 0 --network sepolia

# 3. 列出最近的游戏
npx hardhat game:list --count 5 --network sepolia

# 4. 手动触发开奖（截止时间后）
npx hardhat game:calculate --id 0 --network sepolia

# 5. 领取奖金（获胜者）
npx hardhat game:claim --id 0 --network sepolia
```

## 📝 部署示例

完整的部署流程示例：

```bash
# 1. 设置环境
npx hardhat vars set MNEMONIC "your mnemonic phrase here"
npx hardhat vars set INFURA_API_KEY "your_infura_api_key"
npx hardhat vars set ETHERSCAN_API_KEY "your_etherscan_api_key"

# 2. 编译合约
npx hardhat clean
npx hardhat compile --network sepolia

# 3. 部署合约
npx hardhat deploy --network sepolia --tags UniqueNumberGameFactory

# 4. 验证部署
npx hardhat game:address --network sepolia

# 5. 创建第一个游戏
npx hardhat game:create \
  --min 1 --max 20 --players 5 --fee "0.005" --duration 7200 \
  --network sepolia

# 6. 查看游戏状态
npx hardhat game:info --id 0 --network sepolia
```

## ⚠️ 重要注意事项

### FHE 加密差异

**本地测试 vs Sepolia**：
- **本地**: 使用 mock 加密，快速测试
- **Sepolia**: 使用真实 FHE 加密，需要完整的客户端设置

### 数字提交限制

在 Sepolia 上提交加密数字需要：
1. 完整的 FHE 客户端设置
2. 密钥生成和管理
3. 加密输入创建

推荐流程：
1. 在本地完成游戏逻辑测试
2. 在 Sepolia 测试部署和基本功能
3. 集成 FHE 客户端进行完整测试

### Gas 费用

Sepolia 上的操作消耗更多 Gas：
- 合约部署: ~0.01-0.02 ETH
- 创建游戏: ~0.001-0.002 ETH
- FHE 操作: 比普通操作消耗更多

### 网络延迟

Sepolia 操作比本地测试慢：
- 交易确认: 15-30 秒
- 区块时间: ~15 秒
- 解密回调: 可能需要几分钟

## 🔍 故障排除

### 常见问题

1. **"insufficient funds for gas"**
   - 获取更多 Sepolia ETH
   - 检查 Gas 价格设置

2. **"FHEVM compatibility check failed"**
   - 合约可能没有正确继承 SepoliaConfig
   - 检查 FHE 库版本兼容性

3. **"Contract verification failed"**
   - 检查 Etherscan API 密钥
   - 确认网络配置正确

4. **Infura 连接问题**
   - 验证 API 密钥有效性
   - 检查网络连接

### 调试工具

```bash
# 查看账户余额
npx hardhat accounts --network sepolia

# 查看网络状态
npx hardhat node-info --network sepolia

# 查看部署历史
npx hardhat deployments --network sepolia
```

## 🔗 有用链接

- [Sepolia Faucet](https://sepoliafaucet.com/) - 获取测试 ETH
- [Sepolia Explorer](https://sepolia.etherscan.io/) - 区块浏览器
- [Infura Dashboard](https://infura.io/dashboard) - API 管理
- [Zama FHEVM Docs](https://docs.zama.ai/fhevm) - FHE 详细文档

## 📊 部署检查清单

- [ ] 设置环境变量（MNEMONIC, INFURA_API_KEY, ETHERSCAN_API_KEY）
- [ ] 获取足够的 Sepolia ETH
- [ ] 编译合约无错误
- [ ] 部署成功并获得合约地址
- [ ] 合约在 Etherscan 上验证成功
- [ ] FHEVM 兼容性检查通过
- [ ] 可以创建游戏并查看状态
- [ ] 基本任务命令正常工作

部署完成后，保存合约地址以供后续使用！