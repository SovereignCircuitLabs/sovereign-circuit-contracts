// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";

import {NpcCharacter}      from "../src/npc/NpcCharacter.sol";
import {GameItems}         from "../src/npc/GameItems.sol";
import {Npc6551Manager}    from "../src/npc/Npc6551Manager.sol";
import {ERC6551Registry}   from "../src/erc6551/ERC6551Registry.sol";
import {ERC6551Account}    from "../src/erc6551/ERC6551Account.sol";
import {IERC6551Account}   from "../src/erc6551/interfaces/IERC6551Account.sol";
import {IERC6551Executable} from "../src/erc6551/interfaces/IERC6551Executable.sol";

import {ERC20}             from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract MockUSDC is ERC20 {
    constructor() ERC20("USD Coin", "USDC") {}
    function mint(address to, uint256 amount) external { _mint(to, amount); }
    function decimals() public pure override returns (uint8) { return 6; }
}

contract Npc6551Test is Test {
    NpcCharacter     internal npc;
    GameItems        internal items;
    ERC6551Registry  internal registry;
    ERC6551Account   internal accountImpl;
    Npc6551Manager   internal manager;
    MockUSDC         internal usdc;

    address internal deployer = address(0xD0);
    address internal alice    = address(0xA11CE);
    address internal bob      = address(0xB0B);

    function setUp() public {
        vm.startPrank(deployer);
        npc         = new NpcCharacter(deployer);
        items       = new GameItems(deployer, "https://arc.example/items/{id}.json");
        registry    = new ERC6551Registry();
        accountImpl = new ERC6551Account();
        manager     = new Npc6551Manager(npc, items, registry, address(accountImpl));
        npc.setMinter(address(manager), true);
        items.setMinter(address(manager), true);
        vm.stopPrank();

        usdc = new MockUSDC();
    }

    // ---------- helpers ----------
    function _defaultPortfolio()
        internal
        pure
        returns (NpcCharacter.PortfolioConfig memory)
    {
        // Mirrors Unity NpcPortfolioConfig defaults:
        //   livingNeedsWeight=0.35 reserveWeight=0.35 tradingWeight=0.30
        //   minimumLivingBudgetUSDC=0.05  minimumReserveBudgetUSDC=0.05
        //   rebalanceInterval=20s        chainActionCooldown=8s
        //   minTradeUSDC=0.005           maxTradeUSDC=0.05
        return NpcCharacter.PortfolioConfig({
            livingNeedsWeightBps: 3500,
            reserveWeightBps:     3500,
            tradingWeightBps:     3000,
            minimumLivingBudgetUSDC:    50_000,  // 0.05 USDC (6-dec)
            minimumReserveBudgetUSDC:   50_000,  // 0.05 USDC
            rebalanceIntervalSeconds:   20,
            chainActionCooldownSeconds: 8,
            minTradeUSDC: 5_000,                 // 0.005 USDC
            maxTradeUSDC: 50_000                 // 0.05 USDC
        });
    }

    function _defaultNpc() internal pure returns (NpcCharacter.NpcData memory) {
        return NpcCharacter.NpcData({
            npcName: "MerchantBalin",
            metadataURI: "ipfs://npc-1.json",
            archetype: NpcCharacter.Archetype.BalancedTrader,
            riskLevel: 5,
            level: 1,
            reputation: 100,
            portfolio: _defaultPortfolio()
        });
    }

    function _mintNpcTo(address to) internal returns (uint256 tokenId, address tba) {
        (tokenId, tba) = manager.mintNpcAndAccount(to, _defaultNpc());
    }

    // -------------------------------------------------
    // 1. testMintNpc
    // -------------------------------------------------
    function testMintNpc() public {
        (uint256 tokenId, ) = _mintNpcTo(alice);

        assertEq(npc.ownerOf(tokenId), alice, "owner mismatch");
        NpcCharacter.NpcData memory data = npc.getNpc(tokenId);
        assertEq(data.npcName, "MerchantBalin");
        assertEq(uint8(data.archetype), uint8(NpcCharacter.Archetype.BalancedTrader));
        assertEq(data.riskLevel, 5);
        assertEq(data.level, 1);
        assertEq(data.reputation, 100);
        assertEq(npc.tokenURI(tokenId), "ipfs://npc-1.json");

        // Portfolio fields mirror Unity NpcPortfolioConfig (after unit conversion).
        NpcCharacter.PortfolioConfig memory p = data.portfolio;
        assertEq(p.livingNeedsWeightBps, 3500);
        assertEq(p.reserveWeightBps,     3500);
        assertEq(p.tradingWeightBps,     3000);
        assertEq(p.minimumLivingBudgetUSDC,    50_000);
        assertEq(p.minimumReserveBudgetUSDC,   50_000);
        assertEq(p.rebalanceIntervalSeconds,   20);
        assertEq(p.chainActionCooldownSeconds, 8);
        assertEq(p.minTradeUSDC,  5_000);
        assertEq(p.maxTradeUSDC, 50_000);
    }

    function testUpdatePortfolioByOwner() public {
        (uint256 tokenId, ) = _mintNpcTo(alice);

        NpcCharacter.PortfolioConfig memory p = _defaultPortfolio();
        p.livingNeedsWeightBps = 2000;
        p.reserveWeightBps     = 2000;
        p.tradingWeightBps     = 6000;
        p.maxTradeUSDC         = 100_000;

        vm.prank(alice);
        npc.updatePortfolio(tokenId, p);

        NpcCharacter.PortfolioConfig memory got = npc.getPortfolio(tokenId);
        assertEq(got.tradingWeightBps, 6000);
        assertEq(got.maxTradeUSDC,    100_000);
    }

    function testUpdatePortfolioRejectsNonOwner() public {
        (uint256 tokenId, ) = _mintNpcTo(alice);
        NpcCharacter.PortfolioConfig memory p = _defaultPortfolio();
        vm.prank(bob);
        vm.expectRevert(NpcCharacter.NotNftOwner.selector);
        npc.updatePortfolio(tokenId, p);
    }

    function testRejectsInvalidPortfolioWeights() public {
        NpcCharacter.NpcData memory data = _defaultNpc();
        data.portfolio.tradingWeightBps = 9999; // sum != 10000

        vm.expectRevert(NpcCharacter.InvalidPortfolioWeights.selector);
        manager.mintNpcAndAccount(alice, data);
    }

    function testRejectsInvalidTradeRange() public {
        NpcCharacter.NpcData memory data = _defaultNpc();
        data.portfolio.minTradeUSDC = 100_000;
        data.portfolio.maxTradeUSDC =  50_000; // min > max

        vm.expectRevert(NpcCharacter.InvalidTradeRange.selector);
        manager.mintNpcAndAccount(alice, data);
    }

    // -------------------------------------------------
    // 2. testCreateTokenBoundAccount
    // -------------------------------------------------
    function testCreateTokenBoundAccount() public {
        (uint256 tokenId, address tba) = _mintNpcTo(alice);

        assertTrue(tba != address(0), "tba zero");
        assertGt(tba.code.length, 0, "tba not deployed");

        // Deterministic: registry.account() must match without redeploy.
        address expected = registry.account(
            address(accountImpl),
            bytes32(0),
            block.chainid,
            address(npc),
            tokenId
        );
        assertEq(tba, expected);

        // Idempotent: calling ensureAccount again returns same address.
        address again = manager.ensureAccount(tokenId);
        assertEq(again, tba);

        // token() must report the binding triplet.
        (uint256 chainId, address tokenContract, uint256 tid) =
            ERC6551Account(payable(tba)).token();
        assertEq(chainId, block.chainid);
        assertEq(tokenContract, address(npc));
        assertEq(tid, tokenId);
    }

    // -------------------------------------------------
    // 3. testTbaOwnerFollowsNpcOwner
    // -------------------------------------------------
    function testTbaOwnerFollowsNpcOwner() public {
        (uint256 tokenId, address tba) = _mintNpcTo(alice);
        ERC6551Account acc = ERC6551Account(payable(tba));

        assertEq(acc.owner(), alice, "owner before transfer");

        vm.prank(alice);
        npc.transferFrom(alice, bob, tokenId);

        assertEq(acc.owner(), bob, "owner after transfer");

        // isValidSigner reflects the same change.
        assertEq(
            acc.isValidSigner(alice, ""),
            bytes4(0),
            "alice still signer after transfer"
        );
        assertEq(
            acc.isValidSigner(bob, ""),
            IERC6551Account.isValidSigner.selector,
            "bob not signer after transfer"
        );
    }

    // -------------------------------------------------
    // 4. testMintErc1155ToNpcTba
    // -------------------------------------------------
    function testMintErc1155ToNpcTba() public {
        (uint256 tokenId, address tba) = _mintNpcTo(alice);

        manager.mintItemToNpcTba(tokenId, items.MARKET_INTEL(), 3);
        manager.mintItemToNpcTba(tokenId, items.RISK_REPORT(),  1);

        assertEq(items.balanceOf(tba, items.MARKET_INTEL()), 3);
        assertEq(items.balanceOf(tba, items.RISK_REPORT()),  1);
        assertEq(items.balanceOf(tba, items.ENERGY_PACK()),  0);
    }

    // -------------------------------------------------
    // 5. testNpcTbaCanHoldAssets  (ETH + ERC20 + ERC1155)
    // -------------------------------------------------
    function testNpcTbaCanHoldAssets() public {
        (uint256 tokenId, address tba) = _mintNpcTo(alice);

        // ETH
        vm.deal(tba, 1 ether);
        assertEq(tba.balance, 1 ether);

        // ERC20 (USDC mock)
        usdc.mint(tba, 1_000_000); // 1 USDC
        assertEq(usdc.balanceOf(tba), 1_000_000);

        // ERC1155
        manager.mintItemToNpcTba(tokenId, items.ENERGY_PACK(), 7);
        assertEq(items.balanceOf(tba, items.ENERGY_PACK()), 7);
    }

    // -------------------------------------------------
    // 6. testOldOwnerCannotExecuteAfterTransfer
    // -------------------------------------------------
    function testOldOwnerCannotExecuteAfterTransfer() public {
        (uint256 tokenId, address tba) = _mintNpcTo(alice);
        manager.mintItemToNpcTba(tokenId, items.SERVICE_VOUCHER(), 4);

        vm.prank(alice);
        npc.transferFrom(alice, bob, tokenId);

        // Alice was the original NFT owner; after transfer she has no authority.
        bytes memory cd = abi.encodeWithSignature(
            "safeTransferFrom(address,address,uint256,uint256,bytes)",
            tba,
            alice,
            items.SERVICE_VOUCHER(),
            1,
            bytes("")
        );
        vm.prank(alice);
        vm.expectRevert(bytes("Invalid signer"));
        IERC6551Executable(payable(tba)).execute(address(items), 0, cd, 0);

        // Balance unchanged.
        assertEq(items.balanceOf(tba, items.SERVICE_VOUCHER()), 4);
    }

    // -------------------------------------------------
    // 7. testNewOwnerCanExecuteAfterTransfer
    // -------------------------------------------------
    function testNewOwnerCanExecuteAfterTransfer() public {
        (uint256 tokenId, address tba) = _mintNpcTo(alice);
        manager.mintItemToNpcTba(tokenId, items.SERVICE_VOUCHER(), 4);

        vm.prank(alice);
        npc.transferFrom(alice, bob, tokenId);

        bytes memory cd = abi.encodeWithSignature(
            "safeTransferFrom(address,address,uint256,uint256,bytes)",
            tba,
            bob,
            items.SERVICE_VOUCHER(),
            2,
            bytes("")
        );

        uint256 stateBefore = ERC6551Account(payable(tba)).state();
        vm.prank(bob);
        IERC6551Executable(payable(tba)).execute(address(items), 0, cd, 0);

        assertEq(items.balanceOf(tba, items.SERVICE_VOUCHER()), 2);
        assertEq(items.balanceOf(bob, items.SERVICE_VOUCHER()), 2);
        assertEq(
            ERC6551Account(payable(tba)).state(),
            stateBefore + 1,
            "state nonce did not advance"
        );
    }
}
