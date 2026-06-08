// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";

import {NpcCharacter} from "../src/npc/NpcCharacter.sol";
import {GameItems} from "../src/npc/GameItems.sol";
import {Npc6551Manager} from "../src/npc/Npc6551Manager.sol";
import {ERC6551Registry} from "../src/erc6551/ERC6551Registry.sol";
import {ERC6551Account} from "../src/erc6551/ERC6551Account.sol";
import {IERC6551Registry} from "../src/erc6551/interfaces/IERC6551Registry.sol";
import {GamePayment} from "../src/GamePayment.sol";
import {NpcNFTPricing} from "../src/npc/NpcNFTPricing.sol";
import {NpcMarketplace} from "../src/npc/NpcMarketplace.sol";

/// @title DeployNpc6551Market
/// @notice Full Arc NPC deployment wired up with the dynamic-pricing
///         marketplace stack (NpcNFTPricing + NpcMarketplace).
///
///         Beyond the base contracts, this script:
///           1. deploys NpcNFTPricing and NpcMarketplace,
///           2. authorizes the marketplace on the pricing module so it can
///              move listed-supply when NPCs are listed / bought / cancelled,
///           3. configures the three archetype class markets (classId =
///              archetype + 1) consumed by the AMM-style scarcity pricing,
///           4. mints 6 NPCs spanning only the three known archetypes
///              (ConservativeSaver / BalancedTrader / AggressiveSpeculator),
///              each with a distinct portfolio / risk / reputation profile,
///           5. approves the marketplace and lists all 6 NPCs for sale.
contract DeployNpc6551Market is Script {
    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(pk);

        bool useCanonical = vm.envOr("USE_CANONICAL_REGISTRY", false);
        address canonical = vm.envOr(
            "CANONICAL_REGISTRY",
            address(0x000000006551c19487814615f02Fa2f9a48Ca91D)
        );

        address usdc = vm.envAddress("USDC_ADDRESS");
        address gatewayAddr = vm.envAddress("GATEWAY_ADDRESS");

        vm.startBroadcast(pk);

        // ---------- Core economy stack ----------

        // NPC ERC721
        NpcCharacter npc = new NpcCharacter(deployer);

        // ERC6551 Account implementation
        ERC6551Account accountImpl = new ERC6551Account();

        // ERC6551 Registry
        IERC6551Registry registry;
        if (useCanonical && canonical.code.length > 0) {
            registry = IERC6551Registry(canonical);
        } else {
            registry = IERC6551Registry(address(new ERC6551Registry()));
        }

        // GameItems ERC1155
        GameItems items = new GameItems(
            deployer,
            "https://arc.example/items/{id}.json"
        );

        // Manager + grant minter rights
        Npc6551Manager manager = new Npc6551Manager(
            npc,
            items,
            registry,
            address(accountImpl)
        );
        npc.setMinter(address(manager), true);
        items.setMinter(address(manager), true);

        // GamePayment
        GamePayment payment = new GamePayment(
            usdc,
            address(items),
            gatewayAddr,
            address(manager)
        );
        // GamePayment mints items on buy/draw, so it needs minter rights.
        items.setMinter(address(payment), true);
        manager.setGamePayment(address(payment));

        // ---------- Marketplace stack ----------

        // Dynamic pricing module (reads TBA value + archetype scarcity).
        NpcNFTPricing pricing = new NpcNFTPricing(
            address(payment),
            address(npc),
            usdc
        );

        // Non-custodial marketplace.
        NpcMarketplace marketplace = new NpcMarketplace(
            address(npc),
            address(pricing),
            usdc
        );

        // Let the marketplace adjust listed-supply on the pricing module.
        pricing.setAuthorizedMarket(address(marketplace));

        // Class markets keyed by classId = archetype + 1.
        // ConservativeSaver(0)->1, BalancedTrader(1)->2, AggressiveSpeculator(2)->3.
        uint256 conservativeClass = uint256(NpcCharacter.Archetype.ConservativeSaver) + 1;
        uint256 balancedClass = uint256(NpcCharacter.Archetype.BalancedTrader) + 1;
        uint256 aggressiveClass = uint256(NpcCharacter.Archetype.AggressiveSpeculator) + 1;

        // Conservative: cheap, low scarcity sensitivity, tight multiplier cap.
        pricing.setClassMarket(
            conservativeClass,
            2,            // totalSupply (2 conservative NPCs minted below)
            0,            // listedSupply (incremented by listNpc)
            8,            // virtualLiquidity
            500_000,      // basePrice          (0.50 USDC)
            12_000,       // maxMultiplierBps    (1.2x cap)
            3_000         // scarcityWeightBps   (0.30)
        );
        // Balanced: mid price, moderate scarcity sensitivity.
        pricing.setClassMarket(
            balancedClass,
            2,
            0,
            6,
            1_000_000,    // basePrice           (1.00 USDC)
            15_000,       // maxMultiplierBps    (1.5x cap)
            5_000         // scarcityWeightBps   (0.50)
        );
        // Aggressive: premium price, high scarcity sensitivity, wide cap.
        pricing.setClassMarket(
            aggressiveClass,
            2,
            0,
            4,
            2_000_000,    // basePrice           (2.00 USDC)
            20_000,       // maxMultiplierBps    (2.0x cap)
            8_000         // scarcityWeightBps   (0.80)
        );

        // ---------- Mint 6 NPCs (2 per archetype, all distinct) ----------

        uint256[6] memory tokenIds;
        address[6] memory tbas;
        uint256[6] memory minPrices;

        // ---- #1 ConservativeSaver — "MerchantCorin" ----
        {
            NpcCharacter.NpcData memory d = NpcCharacter.NpcData({
                npcName: "MerchantCorin",
                metadataURI: "ipfs://npc-conservative-1.json",
                archetype: NpcCharacter.Archetype.ConservativeSaver,
                riskLevel: 2,
                level: 1,
                reputation: 100,
                portfolio: NpcCharacter.PortfolioConfig({
                    livingNeedsWeightBps: 4500,
                    reserveWeightBps: 4500,
                    tradingWeightBps: 1000,
                    minimumLivingBudgetUSDC: 80_000,
                    minimumReserveBudgetUSDC: 120_000,
                    rebalanceIntervalSeconds: 30,
                    chainActionCooldownSeconds: 12,
                    minTradeUSDC: 2_000,
                    maxTradeUSDC: 15_000
                })
            });
            (tokenIds[0], tbas[0]) = manager.mintNpcAndAccount(deployer, d);
            manager.mintItemToNpcTba(tokenIds[0], items.RISK_REPORT(), 2);
            manager.mintItemToNpcTba(tokenIds[0], items.ENERGY_PACK(), 1);
            minPrices[0] = 400_000; // 0.40 USDC
        }

        // ---- #2 ConservativeSaver — "MerchantDahlia" ----
        {
            NpcCharacter.NpcData memory d = NpcCharacter.NpcData({
                npcName: "MerchantDahlia",
                metadataURI: "ipfs://npc-conservative-2.json",
                archetype: NpcCharacter.Archetype.ConservativeSaver,
                riskLevel: 3,
                level: 2,
                reputation: 140,
                portfolio: NpcCharacter.PortfolioConfig({
                    livingNeedsWeightBps: 5000,
                    reserveWeightBps: 4000,
                    tradingWeightBps: 1000,
                    minimumLivingBudgetUSDC: 100_000,
                    minimumReserveBudgetUSDC: 90_000,
                    rebalanceIntervalSeconds: 45,
                    chainActionCooldownSeconds: 15,
                    minTradeUSDC: 3_000,
                    maxTradeUSDC: 20_000
                })
            });
            (tokenIds[1], tbas[1]) = manager.mintNpcAndAccount(deployer, d);
            manager.mintItemToNpcTba(tokenIds[1], items.RISK_REPORT(), 1);
            manager.mintItemToNpcTba(tokenIds[1], items.ACCESS_PASS(), 1);
            minPrices[1] = 450_000; // 0.45 USDC
        }

        // ---- #3 BalancedTrader — "MerchantBalin" ----
        {
            NpcCharacter.NpcData memory d = NpcCharacter.NpcData({
                npcName: "MerchantBalin",
                metadataURI: "ipfs://npc-balanced-1.json",
                archetype: NpcCharacter.Archetype.BalancedTrader,
                riskLevel: 5,
                level: 1,
                reputation: 100,
                portfolio: NpcCharacter.PortfolioConfig({
                    livingNeedsWeightBps: 3500,
                    reserveWeightBps: 3500,
                    tradingWeightBps: 3000,
                    minimumLivingBudgetUSDC: 50_000,
                    minimumReserveBudgetUSDC: 50_000,
                    rebalanceIntervalSeconds: 20,
                    chainActionCooldownSeconds: 8,
                    minTradeUSDC: 5_000,
                    maxTradeUSDC: 50_000
                })
            });
            (tokenIds[2], tbas[2]) = manager.mintNpcAndAccount(deployer, d);
            manager.mintItemToNpcTba(tokenIds[2], items.ACCESS_PASS(), 1);
            manager.mintItemToNpcTba(tokenIds[2], items.SERVICE_VOUCHER(), 2);
            minPrices[2] = 900_000; // 0.90 USDC
        }

        // ---- #4 BalancedTrader — "MerchantElara" ----
        {
            NpcCharacter.NpcData memory d = NpcCharacter.NpcData({
                npcName: "MerchantElara",
                metadataURI: "ipfs://npc-balanced-2.json",
                archetype: NpcCharacter.Archetype.BalancedTrader,
                riskLevel: 6,
                level: 3,
                reputation: 200,
                portfolio: NpcCharacter.PortfolioConfig({
                    livingNeedsWeightBps: 3000,
                    reserveWeightBps: 3000,
                    tradingWeightBps: 4000,
                    minimumLivingBudgetUSDC: 60_000,
                    minimumReserveBudgetUSDC: 40_000,
                    rebalanceIntervalSeconds: 25,
                    chainActionCooldownSeconds: 10,
                    minTradeUSDC: 6_000,
                    maxTradeUSDC: 60_000
                })
            });
            (tokenIds[3], tbas[3]) = manager.mintNpcAndAccount(deployer, d);
            manager.mintItemToNpcTba(tokenIds[3], items.MARKET_INTEL(), 1);
            manager.mintItemToNpcTba(tokenIds[3], items.SERVICE_VOUCHER(), 1);
            minPrices[3] = 1_000_000; // 1.00 USDC
        }

        // ---- #5 AggressiveSpeculator — "MerchantAragon" ----
        {
            NpcCharacter.NpcData memory d = NpcCharacter.NpcData({
                npcName: "MerchantAragon",
                metadataURI: "ipfs://npc-aggressive-1.json",
                archetype: NpcCharacter.Archetype.AggressiveSpeculator,
                riskLevel: 9,
                level: 1,
                reputation: 100,
                portfolio: NpcCharacter.PortfolioConfig({
                    livingNeedsWeightBps: 2000,
                    reserveWeightBps: 2000,
                    tradingWeightBps: 6000,
                    minimumLivingBudgetUSDC: 30_000,
                    minimumReserveBudgetUSDC: 20_000,
                    rebalanceIntervalSeconds: 10,
                    chainActionCooldownSeconds: 4,
                    minTradeUSDC: 10_000,
                    maxTradeUSDC: 100_000
                })
            });
            (tokenIds[4], tbas[4]) = manager.mintNpcAndAccount(deployer, d);
            manager.mintItemToNpcTba(tokenIds[4], items.MARKET_INTEL(), 2);
            manager.mintItemToNpcTba(tokenIds[4], items.ENERGY_PACK(), 1);
            minPrices[4] = 1_800_000; // 1.80 USDC
        }

        // ---- #6 AggressiveSpeculator — "MerchantFenn" ----
        {
            NpcCharacter.NpcData memory d = NpcCharacter.NpcData({
                npcName: "MerchantFenn",
                metadataURI: "ipfs://npc-aggressive-2.json",
                archetype: NpcCharacter.Archetype.AggressiveSpeculator,
                riskLevel: 10,
                level: 4,
                reputation: 260,
                portfolio: NpcCharacter.PortfolioConfig({
                    livingNeedsWeightBps: 1500,
                    reserveWeightBps: 1500,
                    tradingWeightBps: 7000,
                    minimumLivingBudgetUSDC: 25_000,
                    minimumReserveBudgetUSDC: 15_000,
                    rebalanceIntervalSeconds: 8,
                    chainActionCooldownSeconds: 3,
                    minTradeUSDC: 15_000,
                    maxTradeUSDC: 150_000
                })
            });
            (tokenIds[5], tbas[5]) = manager.mintNpcAndAccount(deployer, d);
            manager.mintItemToNpcTba(tokenIds[5], items.MARKET_INTEL(), 3);
            manager.mintItemToNpcTba(tokenIds[5], items.ENERGY_PACK(), 2);
            minPrices[5] = 2_000_000; // 2.00 USDC
        }

        // ---------- Approve marketplace & list all 6 ----------
        // One blanket approval covers every NPC owned by the deployer.
        npc.setApprovalForAll(address(marketplace), true);
        for (uint256 i = 0; i < tokenIds.length; i++) {
            marketplace.listNpc(tokenIds[i], minPrices[i]);
        }

        vm.stopBroadcast();

        // ---------- Summary ----------
        console2.log("---------- Arc NPC Market Deployment ----------");
        console2.log("Deployer             :", deployer);
        console2.log("NPC ERC721           :", address(npc));
        console2.log("ERC6551 Registry     :", address(registry));
        console2.log("ERC6551 Account impl :", address(accountImpl));
        console2.log("GameItems ERC1155    :", address(items));
        console2.log("Npc6551Manager       :", address(manager));
        console2.log("GamePayment          :", address(payment));
        console2.log("NpcNFTPricing        :", address(pricing));
        console2.log("NpcMarketplace       :", address(marketplace));
        console2.log("USDC                 :", usdc);
        console2.log("Gateway Wallet       :", gatewayAddr);
        console2.log("");
        console2.log("Listed 6 NPCs (tokenId / TBA / minPrice):");
        for (uint256 i = 0; i < tokenIds.length; i++) {
            console2.log("  tokenId :", tokenIds[i]);
            console2.log("  TBA     :", tbas[i]);
            console2.log("  minPrice:", minPrices[i]);
        }
    }
}
