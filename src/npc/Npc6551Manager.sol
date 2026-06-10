// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {NpcCharacter} from "./NpcCharacter.sol";
import {GameItems} from "./GameItems.sol";
import {IERC6551Registry} from "../erc6551/interfaces/IERC6551Registry.sol";
import {GamePayment} from "../GamePayment.sol";

/// @title Npc6551Manager
/// @notice Convenience facade that bundles the canonical NPC-economy flow:
///         (1) mint an NPC NFT, (2) ensure its ERC-6551 TBA exists,
///         (3) mint ERC-1155 items into the TBA.
/// @dev    This contract is *only* a minter and orchestrator. It never holds
///         control over the TBA — that authority belongs to whoever owns the
///         NFT at any given moment. Removing this contract from the minter
///         lists on NpcCharacter / GameItems disables it cleanly.
contract Npc6551Manager {
    /// @notice Single deterministic salt for the whole game. Using salt=0
    ///         means each (chainId, NPC NFT, tokenId) maps to exactly one TBA.
    bytes32 public constant SALT = bytes32(0);

    NpcCharacter public immutable npc;
    GameItems public immutable items;
    IERC6551Registry public immutable registry;
    address public immutable accountImpl;
    GamePayment public gamePayment;

    event GamePaymentSet(
        address indexed previousGamePayment,
        address indexed newGamePayment
    );

    event NpcAndAccountReady(
        uint256 indexed tokenId,
        address indexed owner,
        address tba
    );
    event ItemMintedToNpc(
        uint256 indexed tokenId,
        address indexed tba,
        uint256 itemId,
        uint256 amount
    );

    constructor(
        NpcCharacter _npc,
        GameItems _items,
        IERC6551Registry _registry,
        address _accountImpl
    ) {
        npc = _npc;
        items = _items;
        registry = _registry;
        accountImpl = _accountImpl;
    }

    /// @notice Mint a new NPC NFT and atomically create its TBA.
    function mintNpcAndAccount(
        address to,
        NpcCharacter.NpcData calldata data
    ) external returns (uint256 tokenId, address tba) {
        tokenId = npc.mintNpc(to, data);
        tba = registry.createAccount(
            accountImpl,
            SALT,
            block.chainid,
            address(npc),
            tokenId
        );
        emit NpcAndAccountReady(tokenId, to, tba);
    }

    /// @notice View — TBA address for a given NPC tokenId (no deployment).
    function accountOf(uint256 tokenId) external view returns (address) {
        return
            registry.account(
                accountImpl,
                SALT,
                block.chainid,
                address(npc),
                tokenId
            );
    }

    /// @notice Idempotent — deploy the TBA if it isn't deployed yet, else
    ///         return the existing address. Useful for legacy NPCs minted
    ///         before this manager existed.
    function ensureAccount(uint256 tokenId) external returns (address) {
        return
            registry.createAccount(
                accountImpl,
                SALT,
                block.chainid,
                address(npc),
                tokenId
            );
    }

    /// @notice Mint ERC-1155 items directly into an NPC's TBA. Intended for
    ///         game-server actions ("the NPC bought a MarketIntel from the
    ///         shop"). Player-to-NPC trades should go through the TBA's
    ///         execute() path instead.
    function mintItemToNpcTba(
        uint256 tokenId,
        uint256 itemId,
        uint256 amount
    ) external returns (address tba) {
        tba = registry.createAccount(
            accountImpl,
            SALT,
            block.chainid,
            address(npc),
            tokenId
        );
        items.mint(tba, itemId, amount, "");
        gamePayment.recordManagerMint(itemId, amount);

        emit ItemMintedToNpc(tokenId, tba, itemId, amount);
    }

    function setGamePayment(address _gamePayment) external {
        require(address(gamePayment) == address(0), "GamePayment already set");
        require(_gamePayment != address(0), "Invalid GamePayment");

        emit GamePaymentSet(address(gamePayment), _gamePayment);
        gamePayment = GamePayment(payable(_gamePayment));
    }
}
