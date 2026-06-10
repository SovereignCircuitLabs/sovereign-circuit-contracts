// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";

import {NpcCharacter}     from "../src/npc/NpcCharacter.sol";
import {GameItems}        from "../src/npc/GameItems.sol";
import {Npc6551Manager}   from "../src/npc/Npc6551Manager.sol";
import {ERC6551Registry}  from "../src/erc6551/ERC6551Registry.sol";
import {ERC6551Account}   from "../src/erc6551/ERC6551Account.sol";
import {IERC6551Registry} from "../src/erc6551/interfaces/IERC6551Registry.sol";

/// @notice Deploys the full Arc NPC stack and produces one demo NPC + TBA.
///
/// Usage:
///   PRIVATE_KEY=0x... \
///   forge script script/DeployNpc6551.s.sol:DeployNpc6551 \
///     --rpc-url $ARC_RPC_URL --broadcast
///
/// Optional env:
///   USE_CANONICAL_REGISTRY=true        (re-use already-deployed registry)
///   CANONICAL_REGISTRY=0x000000006551c19487814615f02fa2f9a48ca91d
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

        // 1. NPC ERC721
        NpcCharacter npc = new NpcCharacter(deployer);

        // 2. ERC6551 Account implementation (UUPS-style logic contract; proxies
        //    deployed by the registry will delegatecall here).
        ERC6551Account accountImpl = new ERC6551Account();

        // 3. ERC6551 Registry — either reuse the canonical singleton if it's
        //    available on Arc, or deploy our own copy. Deterministic addresses
        //    are reproducible across either path *as long as the salt and the
        //    accountImpl bytecode are identical*.
        IERC6551Registry registry;
        if (useCanonical && canonical.code.length > 0) {
            registry = IERC6551Registry(canonical);
        } else {
            registry = IERC6551Registry(address(new ERC6551Registry()));
        }

        // 4. GameItems ERC1155
        GameItems items = new GameItems(
            deployer,
            "https://arc.example/items/{id}.json"
        );

        // 5. Manager + grant minter rights
        Npc6551Manager manager = new Npc6551Manager(
            npc,
            items,
            registry,
            address(accountImpl)
        );
        npc.setMinter(address(manager), true);
        items.setMinter(address(manager), true);

        // 6. Demo: mint one NPC + create its TBA + drop a starter MarketIntel
        //    Portfolio mirrors Unity NpcPortfolioConfig defaults.
        NpcCharacter.PortfolioConfig memory portfolio = NpcCharacter.PortfolioConfig({
            livingNeedsWeightBps: 3500,
            reserveWeightBps:     3500,
            tradingWeightBps:     3000,
            minimumLivingBudgetUSDC:    50_000,   // 0.05 USDC (6-dec smallest unit)
            minimumReserveBudgetUSDC:   50_000,
            rebalanceIntervalSeconds:   20,
            chainActionCooldownSeconds: 8,
            minTradeUSDC:  5_000,                  // 0.005 USDC
            maxTradeUSDC: 50_000                   // 0.05  USDC
        });
        NpcCharacter.NpcData memory data = NpcCharacter.NpcData({
            npcName: "MerchantBalin",
            metadataURI: "ipfs://npc-1.json",
            archetype: NpcCharacter.Archetype.BalancedTrader,
            riskLevel: 5,
            level: 1,
            reputation: 100,
            portfolio: portfolio
        });
        (uint256 tokenId, address tba) = manager.mintNpcAndAccount(deployer, data);
        manager.mintItemToNpcTba(tokenId, items.ACCESS_PASS(), 1);
        manager.mintItemToNpcTba(tokenId, items.SERVICE_VOUCHER(), 1);

        vm.stopBroadcast();

        console2.log("---------- Arc NPC Deployment ----------");
        console2.log("Deployer             :", deployer);
        console2.log("NPC ERC721           :", address(npc));
        console2.log("ERC6551 Registry     :", address(registry));
        console2.log("ERC6551 Account impl :", address(accountImpl));
        console2.log("GameItems ERC1155    :", address(items));
        console2.log("Npc6551Manager       :", address(manager));
        console2.log("Demo NPC tokenId     :", tokenId);
        console2.log("Demo NPC TBA address :", tba);
    }
}
