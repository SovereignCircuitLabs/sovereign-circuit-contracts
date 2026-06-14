# Sovereign Circuit — Smart Contracts

**Language / 语言 / 語言**:
[English](#english) ｜ [简体中文](#简体中文) ｜ [繁體中文](#繁體中文)

**Links / 链接 / 連結**:

- 🌐 Website / 项目官网 / 專案官網: https://sovereign-circuit.com/
- 📺 Video intro / 视频介绍 / 影片介紹: https://www.youtube.com/watch?v=CTXvgje_fYE
- Unity Client: https://github.com/SovereignCircuitLabs/sovereign-circuit-unity
- Smart Contracts (this repo): https://github.com/SovereignCircuitLabs/sovereign-circuit-contracts
- x402 Seller Server: https://github.com/SovereignCircuitLabs/sovereign-circuit-server

---

## English

### 1. Overview

This repository holds the **on-chain layer** of the **Arc-Chain-Economy-System** — an experimental **Autonomous Agentic Economy** on [Arc Network](https://arc.network/) where AI NPCs own wallets, hold assets, pay for services and trade with each other.

The contracts give every NPC a **dual on-chain identity** and a complete in-game economy:

- An **ERC-721 identity + strategy record** (`NpcCharacter`) — each NPC NFT also stores its economic config on-chain, and can bind an off-chain payment wallet for x402.
- An **ERC-6551 Token Bound Account (TBA)** per NPC NFT — a smart-contract wallet that custodies that NPC's USDC and ERC-1155 inventory, with ownership following the NFT automatically.
- An **ERC-1155 game-item economy** (`GameItems`) priced by a **bonding-curve AMM** (`GamePayment`), which also bridges into the **Circle Gateway Wallet** for x402 nanopayments.
- A **dynamic NPC-NFT marketplace** (`NpcNFTPricing` + `NpcMarketplace`) whose price tracks each NPC's TBA net worth and an archetype scarcity multiplier.

> Closed loop: player wallet logs in → NPC NFTs enumerated → TBAs resolved → NPCs trade items via the bonding curve / x402 → ERC-1155 mints into NPC TBAs → NPC TBA value grows → NPC NFTs are bought/sold on the marketplace at a price derived from that value.

**TBA vs Payment Wallet.** Each NPC is backed by two distinct artifacts. The **TBA (ERC-6551)** is the NPC's asset-custody wallet, deterministically derived from the NFT (`registry.account(impl, salt=0, chainId, nftAddr, tokenId)`); it holds USDC + ERC-1155 items and transfers with the NFT. The **Payment Wallet** is a separate off-chain EOA registered via `bindPaymentWallet(tokenId, addr)`, used only to sign EIP-3009 `transferWithAuthorization` payloads for x402. It holds no assets, can be rotated/revoked by the NFT owner, and is auto-cleared (with a version bump) on any NFT transfer so a previous operator's key cannot keep signing.

### 2. Tech Stack

| Layer                 | Technology                                                                 |
| --------------------- | -------------------------------------------------------------------------- |
| Language / compiler   | **Solidity ^0.8.20**, `via_ir = true` + optimizer (deploy scripts have deep stacks) |
| Toolchain             | **Foundry** (`forge` / `cast` / `anvil`)                                   |
| Libraries             | **OpenZeppelin Contracts** (ERC721URIStorage, ERC1155, Ownable, SafeERC20, ERC1155Holder) + **forge-std** |
| Chain                 | **Arc Testnet** (EVM, chainId `5042002`), native **USDC** (6 decimals)     |
| NPC identity          | **ERC-721** (`NpcCharacter`) with on-chain `PortfolioConfig`               |
| Token Bound Account   | **ERC-6551** (`ERC6551Registry` + `ERC6551Account`, ERC-1167 minimal proxy via `CREATE2`, fixed `salt = 0`) |
| Game items            | **ERC-1155** (`GameItems`: MarketIntel / EnergyPack / AccessPass / RiskReport / ServiceVoucher) |
| Item pricing          | Bonding-curve AMM inside `GamePayment` (linear buy curve, fixed sell spread) |
| NPC marketplace       | `NpcNFTPricing` (TBA-value + scarcity) + `NpcMarketplace` (non-custodial)  |
| Micropayments         | **Circle Gateway Wallet** integration (`IGatewayWallet`) for **x402** EIP-3009 settlement |

### 3. Contracts at a Glance

- **`NpcCharacter` (ERC-721)** — On-chain NPC identity that also stores the strategy `PortfolioConfig` and can bind an x402 payment wallet; the binding auto-clears on NFT transfer.
- **`GameItems` (ERC-1155)** — Five fixed game-item types (MarketIntel / EnergyPack / AccessPass / RiskReport / ServiceVoucher), minter-gated minting.
- **`erc6551/` (ERC6551Registry + ERC6551Account)** — Deterministically derives one TBA smart-contract wallet per NPC NFT (`CREATE2`, fixed salt=0) to custody its USDC and items; control follows the NFT.
- **`Npc6551Manager`** — Orchestration facade that mints the NFT, creates the TBA, and mints items into it in one call.
- **`GamePayment`** — Bonding-curve AMM for items (buy/sell/buyback) plus a Circle Gateway Wallet bridge that funds x402 nanopayments.
- **`NpcNFTPricing`** — Quotes each NPC's price from its TBA net worth and an archetype scarcity multiplier.
- **`NpcMarketplace`** — Non-custodial NPC-NFT trading settled in USDC.

### 4. Deployment

#### 4.1 Prerequisites
- [Foundry](https://book.getfoundry.sh/getting-started/installation) (`forge` / `cast`).
- A funded Arc Testnet deployer key (native USDC from the [Circle Faucet](https://faucet.circle.com)).
- The Arc-deployed **USDC** address and **Circle Gateway Wallet** address.

#### 4.2 Install & build
```bash
git clone --recurse-submodules <this-repo-url>
cd <repo>

# if you cloned without submodules:
forge install            # pulls lib/forge-std + lib/openzeppelin-contracts

forge build
forge test               # runs test/Npc6551.t.sol
```

#### 4.3 Configure environment
Copy `.env.example` → `.env` and fill in:
```bash
ARC_TESTNET_RPC_URL="https://rpc.testnet.arc.network"
PRIVATE_KEY="0x<deployer-private-key>"
USDC_ADDRESS="0x<usdc-on-arc>"
GATEWAY_ADDRESS="0x<circle-gateway-wallet-on-arc>"
```
```bash
source .env
```

#### 4.4 Choose a deploy script
| Script | Contract | What it deploys |
| ------ | -------- | --------------- |
| `script/DeployNpc6551Market.s.sol` | `DeployNpc6551Market` | **Recommended / full end-to-end.** Core stack + `GamePayment` + `NpcNFTPricing` + `NpcMarketplace`, configures the 3 archetype class markets, mints **6 NPCs** (2 per archetype) and lists them for sale. |
| `script/DeployAggregateNpc6551.s.sol` | `DeployNpc6551` | Core stack **+ `GamePayment`**, mints **3 demo NPCs** (one per archetype). No marketplace. |
| `script/DeployAggressiveNpc6551.s.sol`<br>`script/DeployBalancedNpc6551.s.sol`<br>`script/DeployConservativeNpc6551.s.sol` | `DeployNpc6551` | Minimal **base stack** (NpcCharacter + ERC-6551 + GameItems + Npc6551Manager) + 1 demo NPC. No `GamePayment`, no marketplace — useful for smoke-testing identity + TBA only. |

#### 4.5 Deploy
```bash
# Full marketplace deployment (recommended):
forge script script/DeployNpc6551Market.s.sol:DeployNpc6551Market \
--rpc-url $ARC_TESTNET_RPC_URL --private-key $PRIVATE_KEY \
--via-ir --broadcast --slow
```
Each script's `run()` reads `PRIVATE_KEY`, `USDC_ADDRESS`, `GATEWAY_ADDRESS` from the environment and prints every deployed address (NPC ERC-721, registry, account impl, GameItems, Npc6551Manager, GamePayment, NpcNFTPricing, NpcMarketplace, plus the minted tokenIds / TBAs) in the final summary. Save these.

> Minter wiring and `manager.setGamePayment(...)` are performed **inside** the scripts, so no manual post-deploy permission setup is required for the bundled flow.

#### 4.6 Post-deploy
1. Copy the printed addresses into the **Unity client** config and the **x402 Seller server** `.env` (`GAMEITEMS_ADDRESS`, GamePayment, NpcCharacter, marketplace, etc.).
2. The **owner of `GamePayment` is the trusted x402 relayer** — only it can call `mintRandomX402` / `buyItemX402`. Point the seller server at that key (or `transferOwnership` to the server's address).
3. Fund x402 by calling `GamePayment.depositToGateway(amount)` (the contract must hold USDC first), and add the settlement delegate with `addGatewayDelegate(...)` if your Gateway flow requires it.

---

## 简体中文

### 1. 项目介绍

本仓库是 **Arc-Chain-Economy-System** 的**链上层**——一个构建在 [Arc Network](https://arc.network/) 上的实验性 **自治智能体经济**：AI NPC 拥有自己的钱包、持有资产、为服务付费并彼此交易。

这些合约为每个 NPC 提供**双重链上身份**与一整套游戏内经济：

- **ERC-721 身份 + 策略记录**（`NpcCharacter`）——每个 NPC NFT 同时把经济参数存在链上,并可绑定一个用于 x402 的链下支付钱包。
- 每个 NPC NFT 对应一个 **ERC-6551 Token Bound Account（TBA）**——一个托管该 NPC 的 USDC 与 ERC-1155 库存的智能合约钱包,所有权随 NFT 自动转移。
- 由**联合曲线 AMM**（`GamePayment`）定价的 **ERC-1155 游戏道具经济**（`GameItems`）,并桥接到 **Circle Gateway Wallet** 完成 x402 微支付。
- **动态 NPC-NFT 交易所**（`NpcNFTPricing` + `NpcMarketplace`）,价格跟随每个 NPC 的 TBA 净值与按原型（archetype）计算的稀缺度乘数。

> 闭环：玩家钱包登录 → 枚举 NPC NFT → 解析 TBA → NPC 通过联合曲线 / x402 交易道具 → ERC-1155 铸造进 NPC TBA → NPC TBA 价值增长 → NPC NFT 在交易所按该价值派生的价格被买卖。

**TBA 与 PaymentWallet 的区别。** 每个 NPC 对应两个完全不同的实体。**TBA（ERC-6551）** 是资产托管钱包,由 NFT 确定性派生（`registry.account(impl, salt=0, chainId, nftAddr, tokenId)`）,持有 USDC + ERC-1155 并随 NFT 转移。**PaymentWallet** 则是另一个链下 EOA,通过 `bindPaymentWallet(tokenId, addr)` 注册,仅用于对 x402 的 EIP-3009 `transferWithAuthorization` 签名。它不持有资产,可由 NFT 持有人随时轮换/吊销,并在任何 NFT 转移时被自动清空（同时 version 自增）,使旧操作者的私钥无法继续签名。

### 2. 技术栈

| 层级            | 技术                                                                       |
| --------------- | -------------------------------------------------------------------------- |
| 语言 / 编译器   | **Solidity ^0.8.20**,开启 `via_ir = true` + optimizer（部署脚本局部变量多） |
| 工具链          | **Foundry**（`forge` / `cast` / `anvil`）                                  |
| 依赖库          | **OpenZeppelin Contracts**（ERC721URIStorage、ERC1155、Ownable、SafeERC20、ERC1155Holder）+ **forge-std** |
| 区块链          | **Arc Testnet**（EVM,chainId `5042002`）,链原生 **USDC**（6 位小数）     |
| NPC 身份        | **ERC-721**（`NpcCharacter`）,链上保存 `PortfolioConfig`                   |
| TBA             | **ERC-6551**（`ERC6551Registry` + `ERC6551Account`,通过 `CREATE2` 部署 ERC-1167 极简代理,固定 `salt = 0`） |
| 游戏道具        | **ERC-1155**（`GameItems`：MarketIntel / EnergyPack / AccessPass / RiskReport / ServiceVoucher） |
| 道具定价        | `GamePayment` 内置联合曲线 AMM（线性买价 + 固定卖出价差）                   |
| NPC 交易所      | `NpcNFTPricing`（TBA 净值 + 稀缺度）+ `NpcMarketplace`（非托管）            |
| 微支付          | 集成 **Circle Gateway Wallet**（`IGatewayWallet`）完成 **x402** EIP-3009 结算 |

### 3. 合约一览

- **`NpcCharacter`（ERC-721）** — NPC 链上身份,链上保存策略参数 `PortfolioConfig`,并可绑定 x402 支付钱包;NFT 转移时自动清空绑定。
- **`GameItems`（ERC-1155）** — 5 种固定游戏道具(情报/能量/通行证/风控报告/服务券),minter 限定铸造。
- **`erc6551/`（ERC6551Registry + ERC6551Account）** — 每个 NPC NFT 经 `CREATE2`(固定 salt=0)确定性派生一个 TBA 智能合约钱包,托管其 USDC 与道具,控制权随 NFT 转移。
- **`Npc6551Manager`** — 编排门面,一步完成「铸 NFT + 建 TBA + 向 TBA 铸道具」。
- **`GamePayment`** — 道具联合曲线 AMM(买/卖/回购),并桥接 Circle Gateway Wallet 为 x402 微支付注资。
- **`NpcNFTPricing`** — 按 NPC 的 TBA 净值 + 原型稀缺度动态报价。
- **`NpcMarketplace`** — 非托管 NPC-NFT 交易,USDC 结算。

### 4. 部署教程

#### 4.1 前置依赖
- [Foundry](https://book.getfoundry.sh/getting-started/installation)（`forge` / `cast`）。
- 一个在 Arc Testnet 上有原生 USDC 的部署私钥（[Circle Faucet](https://faucet.circle.com) 领取）。
- Arc 上已部署的 **USDC** 地址与 **Circle Gateway Wallet** 地址。

#### 4.2 安装与编译
```bash
git clone --recurse-submodules <本仓库地址>
cd <repo>

# 若未带子模块克隆：
forge install            # 拉取 lib/forge-std + lib/openzeppelin-contracts

forge build
forge test               # 运行 test/Npc6551.t.sol
```

#### 4.3 配置环境变量
复制 `.env.example` → `.env` 并填写：
```bash
ARC_TESTNET_RPC_URL="https://rpc.testnet.arc.network"
PRIVATE_KEY="0x<部署者私钥>"
USDC_ADDRESS="0x<Arc 上的 USDC>"
GATEWAY_ADDRESS="0x<Arc 上的 Circle Gateway Wallet>"
```
```bash
source .env
```

#### 4.4 选择部署脚本
| 脚本 | 合约 | 部署内容 |
| ---- | ---- | -------- |
| `script/DeployNpc6551Market.s.sol` | `DeployNpc6551Market` | **推荐 / 完整端到端。** 核心栈 + `GamePayment` + `NpcNFTPricing` + `NpcMarketplace`,配置三种原型 class market,铸造 **6 个 NPC**（每原型 2 个）并全部挂单出售。 |
| `script/DeployAggregateNpc6551.s.sol` | `DeployNpc6551` | 核心栈 **+ `GamePayment`**,铸造 **3 个示例 NPC**（每原型 1 个）。无交易所。 |
| `script/DeployAggressiveNpc6551.s.sol`<br>`script/DeployBalancedNpc6551.s.sol`<br>`script/DeployConservativeNpc6551.s.sol` | `DeployNpc6551` | 最小**基础栈**（NpcCharacter + ERC-6551 + GameItems + Npc6551Manager）+ 1 个示例 NPC。无 `GamePayment`、无交易所——仅用于验证身份 + TBA。 |

#### 4.5 执行部署
```bash
# 完整交易所部署（推荐）：
forge script script/DeployNpc6551Market.s.sol:DeployNpc6551Market \
--rpc-url $ARC_TESTNET_RPC_URL --private-key $PRIVATE_KEY \
--via-ir --broadcast --slow
```
每个脚本的 `run()` 会从环境读取 `PRIVATE_KEY`、`USDC_ADDRESS`、`GATEWAY_ADDRESS`,并在结尾打印所有已部署地址（NPC ERC-721、registry、account 实现、GameItems、Npc6551Manager、GamePayment、NpcNFTPricing、NpcMarketplace,以及铸出的 tokenId / TBA）。请妥善保存。

> minter 授权与 `manager.setGamePayment(...)` 均在脚本**内部**完成,打包流程无需手动做部署后权限配置。

#### 4.6 部署后
1. 把打印出的地址填入 **Unity 客户端** 配置与 **x402 Seller server** 的 `.env`（`GAMEITEMS_ADDRESS`、GamePayment、NpcCharacter、marketplace 等）。
2. **`GamePayment` 的 owner 就是受信任的 x402 relayer**——只有它能调用 `mintRandomX402` / `buyItemX402`。把 seller server 指向该私钥,或用 `transferOwnership` 移交给 server 地址。
3. 调用 `GamePayment.depositToGateway(amount)` 为 x402 注资（合约需先持有 USDC）；若 Gateway 流程需要,用 `addGatewayDelegate(...)` 添加结算 delegate。

---

## 繁體中文

### 1. 專案介紹

本倉庫是 **Arc-Chain-Economy-System** 的**鏈上層**——一個建構在 [Arc Network](https://arc.network/) 上的實驗性 **自治智能體經濟**：AI NPC 擁有自己的錢包、持有資產、為服務付費並彼此交易。

這些合約為每個 NPC 提供**雙重鏈上身份**與一整套遊戲內經濟：

- **ERC-721 身份 + 策略記錄**（`NpcCharacter`）——每個 NPC NFT 同時把經濟參數存在鏈上,並可綁定一個用於 x402 的鏈下支付錢包。
- 每個 NPC NFT 對應一個 **ERC-6551 Token Bound Account（TBA）**——託管該 NPC 的 USDC 與 ERC-1155 庫存的智能合約錢包,所有權隨 NFT 自動轉移。
- 由**聯合曲線 AMM**（`GamePayment`）定價的 **ERC-1155 遊戲道具經濟**（`GameItems`）,並橋接到 **Circle Gateway Wallet** 完成 x402 微支付。
- **動態 NPC-NFT 交易所**（`NpcNFTPricing` + `NpcMarketplace`）,價格跟隨每個 NPC 的 TBA 淨值與依原型（archetype）計算的稀缺度乘數。

> 閉環：玩家錢包登入 → 列舉 NPC NFT → 解析 TBA → NPC 透過聯合曲線 / x402 交易道具 → ERC-1155 鑄造進 NPC TBA → NPC TBA 價值增長 → NPC NFT 於交易所依該價值派生的價格被買賣。

**TBA 與 PaymentWallet 的差異。** 每個 NPC 對應兩個完全不同的實體。**TBA（ERC-6551）** 是資產託管錢包,由 NFT 確定性派生（`registry.account(impl, salt=0, chainId, nftAddr, tokenId)`）,持有 USDC + ERC-1155 並隨 NFT 轉移。**PaymentWallet** 則是另一個鏈下 EOA,透過 `bindPaymentWallet(tokenId, addr)` 註冊,僅用於對 x402 的 EIP-3009 `transferWithAuthorization` 簽名。它不持有資產,可由 NFT 持有人隨時輪換/撤銷,並在任何 NFT 轉移時被自動清空（同時 version 自增）,使舊操作者的私鑰無法繼續簽名。

### 2. 技術堆疊

| 層級            | 技術                                                                       |
| --------------- | -------------------------------------------------------------------------- |
| 語言 / 編譯器   | **Solidity ^0.8.20**,開啟 `via_ir = true` + optimizer（部署腳本區域變數多） |
| 工具鏈          | **Foundry**（`forge` / `cast` / `anvil`）                                  |
| 相依套件        | **OpenZeppelin Contracts**（ERC721URIStorage、ERC1155、Ownable、SafeERC20、ERC1155Holder）+ **forge-std** |
| 區塊鏈          | **Arc Testnet**（EVM,chainId `5042002`）,鏈原生 **USDC**（6 位小數）     |
| NPC 身份        | **ERC-721**（`NpcCharacter`）,鏈上保存 `PortfolioConfig`                   |
| TBA             | **ERC-6551**（`ERC6551Registry` + `ERC6551Account`,透過 `CREATE2` 部署 ERC-1167 極簡代理,固定 `salt = 0`） |
| 遊戲道具        | **ERC-1155**（`GameItems`：MarketIntel / EnergyPack / AccessPass / RiskReport / ServiceVoucher） |
| 道具定價        | `GamePayment` 內建聯合曲線 AMM（線性買價 + 固定賣出價差）                   |
| NPC 交易所      | `NpcNFTPricing`（TBA 淨值 + 稀缺度）+ `NpcMarketplace`（非託管）            |
| 微支付          | 整合 **Circle Gateway Wallet**（`IGatewayWallet`）完成 **x402** EIP-3009 結算 |

### 3. 合約一覽

- **`NpcCharacter`（ERC-721）** — NPC 鏈上身份,鏈上保存策略參數 `PortfolioConfig`,並可綁定 x402 支付錢包;NFT 轉移時自動清空綁定。
- **`GameItems`（ERC-1155）** — 5 種固定遊戲道具(情報/能量/通行證/風控報告/服務券),minter 限定鑄造。
- **`erc6551/`（ERC6551Registry + ERC6551Account）** — 每個 NPC NFT 經 `CREATE2`(固定 salt=0)確定性派生一個 TBA 智能合約錢包,託管其 USDC 與道具,控制權隨 NFT 轉移。
- **`Npc6551Manager`** — 編排門面,一步完成「鑄 NFT + 建 TBA + 向 TBA 鑄道具」。
- **`GamePayment`** — 道具聯合曲線 AMM(買/賣/回購),並橋接 Circle Gateway Wallet 為 x402 微支付注資。
- **`NpcNFTPricing`** — 依 NPC 的 TBA 淨值 + 原型稀缺度動態報價。
- **`NpcMarketplace`** — 非託管 NPC-NFT 交易,USDC 結算。

### 4. 部署教學

#### 4.1 前置需求
- [Foundry](https://book.getfoundry.sh/getting-started/installation)（`forge` / `cast`）。
- 一個在 Arc Testnet 上持有原生 USDC 的部署私鑰（[Circle Faucet](https://faucet.circle.com) 領取）。
- Arc 上已部署的 **USDC** 位址與 **Circle Gateway Wallet** 位址。

#### 4.2 安裝與編譯
```bash
git clone --recurse-submodules <本倉庫位址>
cd <repo>

# 若未帶子模組克隆：
forge install            # 拉取 lib/forge-std + lib/openzeppelin-contracts

forge build
forge test               # 執行 test/Npc6551.t.sol
```

#### 4.3 設定環境變數
複製 `.env.example` → `.env` 並填寫：
```bash
ARC_TESTNET_RPC_URL="https://rpc.testnet.arc.network"
PRIVATE_KEY="0x<部署者私鑰>"
USDC_ADDRESS="0x<Arc 上的 USDC>"
GATEWAY_ADDRESS="0x<Arc 上的 Circle Gateway Wallet>"
```
```bash
source .env
```

#### 4.4 選擇部署腳本
| 腳本 | 合約 | 部署內容 |
| ---- | ---- | -------- |
| `script/DeployNpc6551Market.s.sol` | `DeployNpc6551Market` | **推薦 / 完整端對端。** 核心堆疊 + `GamePayment` + `NpcNFTPricing` + `NpcMarketplace`,設定三種原型 class market,鑄造 **6 個 NPC**（每原型 2 個）並全部掛單出售。 |
| `script/DeployAggregateNpc6551.s.sol` | `DeployNpc6551` | 核心堆疊 **+ `GamePayment`**,鑄造 **3 個範例 NPC**（每原型 1 個）。無交易所。 |
| `script/DeployAggressiveNpc6551.s.sol`<br>`script/DeployBalancedNpc6551.s.sol`<br>`script/DeployConservativeNpc6551.s.sol` | `DeployNpc6551` | 最小**基礎堆疊**（NpcCharacter + ERC-6551 + GameItems + Npc6551Manager）+ 1 個範例 NPC。無 `GamePayment`、無交易所——僅用於驗證身份 + TBA。 |

#### 4.5 執行部署
```bash
# 完整交易所部署（推薦）：
forge script script/DeployNpc6551Market.s.sol:DeployNpc6551Market \
--rpc-url $ARC_TESTNET_RPC_URL --private-key $PRIVATE_KEY \
--via-ir --broadcast --slow
```
每個腳本的 `run()` 會從環境讀取 `PRIVATE_KEY`、`USDC_ADDRESS`、`GATEWAY_ADDRESS`,並在結尾印出所有已部署位址（NPC ERC-721、registry、account 實作、GameItems、Npc6551Manager、GamePayment、NpcNFTPricing、NpcMarketplace,以及鑄出的 tokenId / TBA）。請妥善保存。

> minter 授權與 `manager.setGamePayment(...)` 均在腳本**內部**完成,打包流程無需手動做部署後權限設定。

#### 4.6 部署後
1. 把印出的位址填入 **Unity 客戶端** 設定與 **x402 Seller server** 的 `.env`（`GAMEITEMS_ADDRESS`、GamePayment、NpcCharacter、marketplace 等）。
2. **`GamePayment` 的 owner 就是受信任的 x402 relayer**——只有它能呼叫 `mintRandomX402` / `buyItemX402`。把 seller server 指向該私鑰,或用 `transferOwnership` 移交給 server 位址。
3. 呼叫 `GamePayment.depositToGateway(amount)` 為 x402 注資（合約需先持有 USDC）；若 Gateway 流程需要,用 `addGatewayDelegate(...)` 新增結算 delegate。

---

## License

See [`LICENSE`](./LICENSE).
