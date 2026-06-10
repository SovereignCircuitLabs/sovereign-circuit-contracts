# Arc-Chain-Economy-System — Smart Contracts

**Language / 语言 / 語言**:
[English](#english) ｜ [简体中文](#简体中文) ｜ [繁體中文](#繁體中文)

- Unity Client: https://github.com/NPCs-Agent-Economy-System/Arc-Chain-Economy-System
- Smart Contracts (this repo): Arc-Chain-Game-Payment
- x402 Seller Server: https://github.com/NPCs-Agent-Economy-System/Arc-Chain-x402-Seller

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

### 3. Contract Architecture

```
            ┌──────────────────────┐
            │     NpcCharacter      │  ERC-721 identity + PortfolioConfig
            │  (+ payment-wallet    │  + bindPaymentWallet / version reset on transfer
            │     binding)          │
            └───────────┬──────────┘
                        │ owns 1:1
            ┌───────────▼──────────┐      derive (salt=0, CREATE2)
            │   ERC6551Registry    │──────────────► ERC6551Account (TBA)
            └──────────────────────┘                holds USDC + ERC-1155
                        ▲
                        │ mint NPC + create TBA + mint items
            ┌───────────┴──────────┐
            │    Npc6551Manager     │  orchestration facade (minter only)
            └───────┬───────┬──────┘
                    │       │ recordManagerMint(id, amount)
        mint items  │       ▼
            ┌───────▼──────────────┐
            │     GameItems         │  ERC-1155, 5 fixed item types
            └───────────▲──────────┘
                        │ mint on buy / sell buyback
            ┌───────────┴──────────┐      deposit / withdraw / delegate
            │     GamePayment       │──────────────► Circle Gateway Wallet (x402)
            │  bonding-curve AMM    │
            └───────────▲──────────┘
                        │ reads TBA item + cash value
            ┌───────────┴──────────┐
            │    NpcNFTPricing      │  price = (base + TBA value) × scarcity(archetype)
            └───────────▲──────────┘
                        │ quote + listed-supply
            ┌───────────┴──────────┐
            │    NpcMarketplace     │  non-custodial NPC-NFT trading (USDC)
            └──────────────────────┘
```

#### `src/npc/NpcCharacter.sol` — ERC-721 NPC identity
- Three archetypes: `ConservativeSaver` / `BalancedTrader` / `AggressiveSpeculator`.
- Stores a `PortfolioConfig` on-chain (budget weights in bps that must sum to `10000`, min living/reserve budgets, rebalance interval, action cooldown, min/max trade size) — a 1:1 mirror of Unity's `NpcPortfolioConfig`; the chain is the source of truth.
- `mintNpc` (minter-gated), `updateAttributes` (minter: level/reputation), `updatePortfolio` (NFT-owner self-service retuning).
- **x402 payment-wallet binding**: `bindPaymentWallet` / `clearPaymentWallet` (NFT owner only). On any transfer/burn, `_update` clears the bound wallet and **increments `npcPaymentVersion`** so off-chain caches and stale signatures are invalidated.

#### `src/npc/GameItems.sol` — ERC-1155 items
- Five fixed ids: `MARKET_INTEL=1`, `ENERGY_PACK=2`, `ACCESS_PASS=3`, `RISK_REPORT=4`, `SERVICE_VOUCHER=5` (fixed so the Unity client maps id → sprite statically).
- Minter-gated `mint` / `mintBatch`; exposes `name` / `symbol` / `contractURI` for wallets & marketplaces.

#### `src/erc6551/` — Token Bound Accounts
- `ERC6551Registry` + `ERC6551Account` (reference implementation). Each NPC NFT deterministically maps to one TBA via `CREATE2` with a single game-wide `salt = 0`.
- The account exposes `execute`, `token`, `owner`, `isValidSigner/Signature`, and ERC-721/1155 receiver hooks. Authority always belongs to the **current NFT owner** — selling the NFT hands over the TBA.

#### `src/npc/Npc6551Manager.sol` — orchestration facade
- `mintNpcAndAccount` (mint NFT + create TBA atomically), `ensureAccount` (idempotent TBA deploy), `mintItemToNpcTba` (server-driven item drops into a TBA), `accountOf` (view).
- Routes off-curve mints into `GamePayment.recordManagerMint` so bonding-curve supply accounting stays consistent. Disable cleanly by removing it from the minter lists.

#### `src/GamePayment.sol` — item AMM + Circle Gateway bridge
- **Bonding curve** (USDC, 6 decimals): `buyPrice(id) = BASELINE_PRICE(0.10) + circulatingSupply[id] × PRICE_SLOPE(0.005)`, `sellPrice(id) = buyPrice × 95%` (`SELL_SPREAD_BPS`).
- `mintRandom` (user pays curve price for a random item), `mintRandomX402` / `buyItemX402` (owner = trusted x402 relayer mints after off-chain settlement), `sellItem` (buyback into pool liquidity).
- **Circle Gateway Wallet**: `depositToGateway` / `initiateGatewayWithdrawal` / `completeGatewayWithdrawal` / `add|removeGatewayDelegate`, plus balance views — funds the shared wallet that settles x402 nanopayments.
- TBA item-balance read helpers (`getNpcTbaItemBalances`, `getNpcTbaOwnedItems`).

#### `src/npc/NpcNFTPricing.sol` — dynamic NPC pricing
- Per-archetype "class market" (classId = `archetype + 1`) with `basePrice`, `virtualLiquidity`, `maxMultiplierBps`, `scarcityWeightBps`.
- `quoteNpcPrice(tokenId) = (basePrice + TBA total value) × scarcityMultiplier`, where TBA value = ERC-1155 sell value + USDC cash held by the TBA. Scarcity rises as listed supply shrinks (AMM-style), capped by `maxMultiplierBps`.

#### `src/npc/NpcMarketplace.sol` — non-custodial NPC market
- `listNpc` / `cancelListing` / `clearStaleListing` / `buyNpc`. NFTs stay in the seller's wallet (approval-based); `buyNpc` pulls the live `quoteNpcPrice`, settles USDC seller-ward, then transfers the NFT. Reentrancy-guarded; keeps `NpcNFTPricing.listedSupply` in sync.

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

# optional — reuse an already-deployed ERC-6551 registry singleton:
# USE_CANONICAL_REGISTRY=true
# CANONICAL_REGISTRY=0x<registry-address>
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
  --rpc-url "$ARC_TESTNET_RPC_URL" \
  --broadcast -vvvv
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

### 3. 合约架构

```
            ┌──────────────────────┐
            │     NpcCharacter      │  ERC-721 身份 + PortfolioConfig
            │  （+ 支付钱包绑定）    │  + bindPaymentWallet / 转移时 version 重置
            └───────────┬──────────┘
                        │ 1:1 拥有
            ┌───────────▼──────────┐      派生（salt=0, CREATE2）
            │   ERC6551Registry    │──────────────► ERC6551Account (TBA)
            └──────────────────────┘                持有 USDC + ERC-1155
                        ▲
                        │ 铸造 NPC + 创建 TBA + 铸造道具
            ┌───────────┴──────────┐
            │    Npc6551Manager     │  编排门面（仅 minter）
            └───────┬───────┬──────┘
                    │       │ recordManagerMint(id, amount)
          铸造道具  │       ▼
            ┌───────▼──────────────┐
            │     GameItems         │  ERC-1155,5 种固定道具
            └───────────▲──────────┘
                        │ 购买时铸造 / 回购
            ┌───────────┴──────────┐      deposit / withdraw / delegate
            │     GamePayment       │──────────────► Circle Gateway Wallet (x402)
            │   联合曲线 AMM        │
            └───────────▲──────────┘
                        │ 读取 TBA 道具 + 现金净值
            ┌───────────┴──────────┐
            │    NpcNFTPricing      │  价格 = (base + TBA 净值) × 稀缺度(archetype)
            └───────────▲──────────┘
                        │ 报价 + 在售供给
            ┌───────────┴──────────┐
            │    NpcMarketplace     │  非托管 NPC-NFT 交易（USDC）
            └──────────────────────┘
```

#### `src/npc/NpcCharacter.sol` — ERC-721 NPC 身份
- 三种原型：`ConservativeSaver` / `BalancedTrader` / `AggressiveSpeculator`。
- 链上保存 `PortfolioConfig`（预算权重 bps,三者必须和为 `10000`；最低生活/储备预算；重平衡间隔；操作冷却；最小/最大交易额）——与 Unity 的 `NpcPortfolioConfig` 1:1 对应,链上为唯一事实来源。
- `mintNpc`（minter 限定）、`updateAttributes`（minter：等级/声誉）、`updatePortfolio`（NFT 持有人自助重调参数）。
- **x402 支付钱包绑定**：`bindPaymentWallet` / `clearPaymentWallet`（仅 NFT 持有人）。任何转移/销毁时 `_update` 会清空已绑定钱包并**自增 `npcPaymentVersion`**,使链下缓存与旧签名失效。

#### `src/npc/GameItems.sol` — ERC-1155 道具
- 五种固定 id：`MARKET_INTEL=1`、`ENERGY_PACK=2`、`ACCESS_PASS=3`、`RISK_REPORT=4`、`SERVICE_VOUCHER=5`（固定以便 Unity 静态映射 id → 贴图）。
- minter 限定的 `mint` / `mintBatch`；暴露 `name` / `symbol` / `contractURI` 供钱包与交易市场展示。

#### `src/erc6551/` — Token Bound Accounts
- `ERC6551Registry` + `ERC6551Account`（参考实现）。每个 NPC NFT 通过 `CREATE2` 配合全局唯一 `salt = 0` 确定性映射到一个 TBA。
- 账户暴露 `execute`、`token`、`owner`、`isValidSigner/Signature` 及 ERC-721/1155 接收钩子。控制权始终归**当前 NFT 持有人**——卖出 NFT 即移交 TBA。

#### `src/npc/Npc6551Manager.sol` — 编排门面
- `mintNpcAndAccount`（原子地铸 NFT + 创建 TBA）、`ensureAccount`（幂等部署 TBA）、`mintItemToNpcTba`（服务端把道具直接铸进 TBA）、`accountOf`（view）。
- 把曲线外的铸造经由 `GamePayment.recordManagerMint` 上报,保持联合曲线供给账目一致。把它从各 minter 列表移除即可干净停用。

#### `src/GamePayment.sol` — 道具 AMM + Circle Gateway 桥
- **联合曲线**（USDC,6 位小数）：`buyPrice(id) = BASELINE_PRICE(0.10) + circulatingSupply[id] × PRICE_SLOPE(0.005)`,`sellPrice(id) = buyPrice × 95%`（`SELL_SPREAD_BPS`）。
- `mintRandom`（用户按曲线价购随机道具）、`mintRandomX402` / `buyItemX402`（owner = 受信任的 x402 relayer,在链下结算后铸造）、`sellItem`（按池内流动性回购）。
- **Circle Gateway Wallet**：`depositToGateway` / `initiateGatewayWithdrawal` / `completeGatewayWithdrawal` / `add|removeGatewayDelegate` 及余额查询——为结算 x402 微支付的共享钱包注资。
- TBA 道具余额读取助手（`getNpcTbaItemBalances`、`getNpcTbaOwnedItems`）。

#### `src/npc/NpcNFTPricing.sol` — 动态 NPC 定价
- 按原型划分的「class market」（classId = `archetype + 1`）,含 `basePrice`、`virtualLiquidity`、`maxMultiplierBps`、`scarcityWeightBps`。
- `quoteNpcPrice(tokenId) = (basePrice + TBA 净值) × 稀缺度乘数`,其中 TBA 净值 = ERC-1155 回购价值 + TBA 持有的 USDC。在售供给越少稀缺度越高（AMM 风格）,上限为 `maxMultiplierBps`。

#### `src/npc/NpcMarketplace.sol` — 非托管 NPC 市场
- `listNpc` / `cancelListing` / `clearStaleListing` / `buyNpc`。NFT 留在卖家钱包（基于授权）；`buyNpc` 取实时 `quoteNpcPrice`,先把 USDC 结给卖家再转移 NFT。带重入保护,并保持 `NpcNFTPricing.listedSupply` 同步。

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

# 可选 —— 复用已部署的 ERC-6551 registry 单例：
# USE_CANONICAL_REGISTRY=true
# CANONICAL_REGISTRY=0x<registry 地址>
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
  --rpc-url "$ARC_TESTNET_RPC_URL" \
  --broadcast -vvvv
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

### 3. 合約架構

```
            ┌──────────────────────┐
            │     NpcCharacter      │  ERC-721 身份 + PortfolioConfig
            │  （+ 支付錢包綁定）    │  + bindPaymentWallet / 轉移時 version 重置
            └───────────┬──────────┘
                        │ 1:1 擁有
            ┌───────────▼──────────┐      派生（salt=0, CREATE2）
            │   ERC6551Registry    │──────────────► ERC6551Account (TBA)
            └──────────────────────┘                持有 USDC + ERC-1155
                        ▲
                        │ 鑄造 NPC + 建立 TBA + 鑄造道具
            ┌───────────┴──────────┐
            │    Npc6551Manager     │  編排門面（僅 minter）
            └───────┬───────┬──────┘
                    │       │ recordManagerMint(id, amount)
          鑄造道具  │       ▼
            ┌───────▼──────────────┐
            │     GameItems         │  ERC-1155,5 種固定道具
            └───────────▲──────────┘
                        │ 購買時鑄造 / 回購
            ┌───────────┴──────────┐      deposit / withdraw / delegate
            │     GamePayment       │──────────────► Circle Gateway Wallet (x402)
            │   聯合曲線 AMM        │
            └───────────▲──────────┘
                        │ 讀取 TBA 道具 + 現金淨值
            ┌───────────┴──────────┐
            │    NpcNFTPricing      │  價格 = (base + TBA 淨值) × 稀缺度(archetype)
            └───────────▲──────────┘
                        │ 報價 + 在售供給
            ┌───────────┴──────────┐
            │    NpcMarketplace     │  非託管 NPC-NFT 交易（USDC）
            └──────────────────────┘
```

#### `src/npc/NpcCharacter.sol` — ERC-721 NPC 身份
- 三種原型：`ConservativeSaver` / `BalancedTrader` / `AggressiveSpeculator`。
- 鏈上保存 `PortfolioConfig`（預算權重 bps,三者必須和為 `10000`；最低生活/儲備預算；重平衡間隔；操作冷卻；最小/最大交易額）——與 Unity 的 `NpcPortfolioConfig` 1:1 對應,鏈上為唯一事實來源。
- `mintNpc`（minter 限定）、`updateAttributes`（minter：等級/聲譽）、`updatePortfolio`（NFT 持有人自助重調參數）。
- **x402 支付錢包綁定**：`bindPaymentWallet` / `clearPaymentWallet`（僅 NFT 持有人）。任何轉移/銷毀時 `_update` 會清空已綁定錢包並**自增 `npcPaymentVersion`**,使鏈下快取與舊簽名失效。

#### `src/npc/GameItems.sol` — ERC-1155 道具
- 五種固定 id：`MARKET_INTEL=1`、`ENERGY_PACK=2`、`ACCESS_PASS=3`、`RISK_REPORT=4`、`SERVICE_VOUCHER=5`（固定以便 Unity 靜態映射 id → 貼圖）。
- minter 限定的 `mint` / `mintBatch`；暴露 `name` / `symbol` / `contractURI` 供錢包與交易市場顯示。

#### `src/erc6551/` — Token Bound Accounts
- `ERC6551Registry` + `ERC6551Account`（參考實作）。每個 NPC NFT 透過 `CREATE2` 搭配全域唯一 `salt = 0` 確定性映射到一個 TBA。
- 帳戶暴露 `execute`、`token`、`owner`、`isValidSigner/Signature` 及 ERC-721/1155 接收掛鉤。控制權始終歸**當前 NFT 持有人**——賣出 NFT 即移交 TBA。

#### `src/npc/Npc6551Manager.sol` — 編排門面
- `mintNpcAndAccount`（原子地鑄 NFT + 建立 TBA）、`ensureAccount`（冪等部署 TBA）、`mintItemToNpcTba`（伺服端把道具直接鑄進 TBA）、`accountOf`（view）。
- 把曲線外的鑄造經由 `GamePayment.recordManagerMint` 上報,保持聯合曲線供給帳目一致。把它從各 minter 列表移除即可乾淨停用。

#### `src/GamePayment.sol` — 道具 AMM + Circle Gateway 橋
- **聯合曲線**（USDC,6 位小數）：`buyPrice(id) = BASELINE_PRICE(0.10) + circulatingSupply[id] × PRICE_SLOPE(0.005)`,`sellPrice(id) = buyPrice × 95%`（`SELL_SPREAD_BPS`）。
- `mintRandom`（使用者依曲線價購隨機道具）、`mintRandomX402` / `buyItemX402`（owner = 受信任的 x402 relayer,在鏈下結算後鑄造）、`sellItem`（依池內流動性回購）。
- **Circle Gateway Wallet**：`depositToGateway` / `initiateGatewayWithdrawal` / `completeGatewayWithdrawal` / `add|removeGatewayDelegate` 及餘額查詢——為結算 x402 微支付的共享錢包注資。
- TBA 道具餘額讀取輔助（`getNpcTbaItemBalances`、`getNpcTbaOwnedItems`）。

#### `src/npc/NpcNFTPricing.sol` — 動態 NPC 定價
- 依原型劃分的「class market」（classId = `archetype + 1`）,含 `basePrice`、`virtualLiquidity`、`maxMultiplierBps`、`scarcityWeightBps`。
- `quoteNpcPrice(tokenId) = (basePrice + TBA 淨值) × 稀缺度乘數`,其中 TBA 淨值 = ERC-1155 回購價值 + TBA 持有的 USDC。在售供給越少稀缺度越高（AMM 風格）,上限為 `maxMultiplierBps`。

#### `src/npc/NpcMarketplace.sol` — 非託管 NPC 市場
- `listNpc` / `cancelListing` / `clearStaleListing` / `buyNpc`。NFT 留在賣家錢包（基於授權）；`buyNpc` 取即時 `quoteNpcPrice`,先把 USDC 結給賣家再轉移 NFT。帶重入保護,並保持 `NpcNFTPricing.listedSupply` 同步。

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

# 可選 —— 複用已部署的 ERC-6551 registry 單例：
# USE_CANONICAL_REGISTRY=true
# CANONICAL_REGISTRY=0x<registry 位址>
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
  --rpc-url "$ARC_TESTNET_RPC_URL" \
  --broadcast -vvvv
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
