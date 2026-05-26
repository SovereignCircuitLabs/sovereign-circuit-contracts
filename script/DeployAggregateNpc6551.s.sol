// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";

import {NpcCharacter} from "../src/npc/NpcCharacter.sol";
import {GameItems} from "../src/npc/GameItems.sol";
import {Npc6551Manager} from "../src/npc/Npc6551Manager.sol";
import {ERC6551Registry} from "../src/erc6551/ERC6551Registry.sol";
import {ERC6551Account} from "../src/erc6551/ERC6551Account.sol";
import {IERC6551Registry} from "../src/erc6551/interfaces/IERC6551Registry.sol";

contract DeployNpc6551 is Script {
    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(pk);

        bool useCanonical = vm.envOr("USE_CANONICAL_REGISTRY", false);
        address canonical = vm.envOr(
            "CANONICAL_REGISTRY",
            address(0x000000006551c19487814615f02Fa2f9a48Ca91D)
        );

        vm.startBroadcast(pk);

        // NPC ERC721
        NpcCharacter npc = new NpcCharacter(deployer);

        // ERC6551 Account implementation
        // (UUPS-style logic contract; proxies deployed by the registry will delegatecall here).
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

        // ---------- NPC #1: AggressiveTrader (Unity prefab: AggressiveTraderNpc) ----------
        NpcCharacter.PortfolioConfig memory aggressivePortfolio = NpcCharacter
            .PortfolioConfig({
                livingNeedsWeightBps: 2000, // 0.20
                reserveWeightBps: 2000, // 0.20
                tradingWeightBps: 6000, // 0.60
                minimumLivingBudgetUSDC: 30_000, // 0.03 USDC
                minimumReserveBudgetUSDC: 20_000, // 0.02 USDC
                rebalanceIntervalSeconds: 10,
                chainActionCooldownSeconds: 4,
                minTradeUSDC: 10_000, // 0.01 USDC
                maxTradeUSDC: 100_000 // 0.10 USDC
            });
        NpcCharacter.NpcData memory aggressiveData = NpcCharacter.NpcData({
            npcName: "MerchantAragon",
            metadataURI: "ipfs://npc-aggressive.json",
            archetype: NpcCharacter.Archetype.AggressiveSpeculator,
            riskLevel: 9,
            level: 1,
            reputation: 100,
            portfolio: aggressivePortfolio
        });
        (uint256 aggressiveTokenId, address aggressiveTba) = manager
            .mintNpcAndAccount(deployer, aggressiveData);
        manager.mintItemToNpcTba(aggressiveTokenId, items.MARKET_INTEL(), 1);
        manager.mintItemToNpcTba(aggressiveTokenId, items.ENERGY_PACK(), 1);

        // ---------- NPC #2: BalancedTrader (Unity prefab: BalancedTraderNpc) ----------
        NpcCharacter.PortfolioConfig memory balancedPortfolio = NpcCharacter
            .PortfolioConfig({
                livingNeedsWeightBps: 3500, // 0.35
                reserveWeightBps: 3500, // 0.35
                tradingWeightBps: 3000, // 0.30
                minimumLivingBudgetUSDC: 50_000, // 0.05 USDC
                minimumReserveBudgetUSDC: 50_000, // 0.05 USDC
                rebalanceIntervalSeconds: 20,
                chainActionCooldownSeconds: 8,
                minTradeUSDC: 5_000, // 0.005 USDC
                maxTradeUSDC: 50_000 // 0.05  USDC
            });
        NpcCharacter.NpcData memory balancedData = NpcCharacter.NpcData({
            npcName: "MerchantBalin",
            metadataURI: "ipfs://npc-balanced.json",
            archetype: NpcCharacter.Archetype.BalancedTrader,
            riskLevel: 5,
            level: 1,
            reputation: 100,
            portfolio: balancedPortfolio
        });
        (uint256 balancedTokenId, address balancedTba) = manager
            .mintNpcAndAccount(deployer, balancedData);
        manager.mintItemToNpcTba(balancedTokenId, items.ACCESS_PASS(), 1);
        manager.mintItemToNpcTba(balancedTokenId, items.SERVICE_VOUCHER(), 1);

        // ---------- NPC #3: ConservativeTrader (Unity prefab: ConservativeTraderNpc) ----------
        NpcCharacter.PortfolioConfig memory conservativePortfolio = NpcCharacter
            .PortfolioConfig({
                livingNeedsWeightBps: 4500, // 0.45
                reserveWeightBps: 4500, // 0.45
                tradingWeightBps: 1000, // 0.10
                minimumLivingBudgetUSDC: 80_000, // 0.08 USDC
                minimumReserveBudgetUSDC: 120_000, // 0.12 USDC
                rebalanceIntervalSeconds: 30,
                chainActionCooldownSeconds: 12,
                minTradeUSDC: 2_000, // 0.002 USDC
                maxTradeUSDC: 15_000 // 0.015 USDC
            });
        NpcCharacter.NpcData memory conservativeData = NpcCharacter.NpcData({
            npcName: "MerchantCorin",
            metadataURI: "ipfs://npc-conservative.json",
            archetype: NpcCharacter.Archetype.ConservativeSaver,
            riskLevel: 2,
            level: 1,
            reputation: 100,
            portfolio: conservativePortfolio
        });
        (uint256 conservativeTokenId, address conservativeTba) = manager
            .mintNpcAndAccount(deployer, conservativeData);
        manager.mintItemToNpcTba(conservativeTokenId, items.RISK_REPORT(), 1);
        manager.mintItemToNpcTba(conservativeTokenId, items.ENERGY_PACK(), 1);
        manager.mintItemToNpcTba(conservativeTokenId, items.MARKET_INTEL(), 1);

        vm.stopBroadcast();

        console2.log("---------- Arc NPC Deployment ----------");
        console2.log("Deployer             :", deployer);
        console2.log("NPC ERC721           :", address(npc));
        console2.log("ERC6551 Registry     :", address(registry));
        console2.log("ERC6551 Account impl :", address(accountImpl));
        console2.log("GameItems ERC1155    :", address(items));
        console2.log("Npc6551Manager       :", address(manager));
        console2.log("");
        console2.log("Aggressive   tokenId :", aggressiveTokenId);
        console2.log("Aggressive   TBA     :", aggressiveTba);
        console2.log("Balanced     tokenId :", balancedTokenId);
        console2.log("Balanced     TBA     :", balancedTba);
        console2.log("Conservative tokenId :", conservativeTokenId);
        console2.log("Conservative TBA     :", conservativeTba);
    }
}
