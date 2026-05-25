// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ERC1155} from "@openzeppelin/contracts/token/ERC1155/ERC1155.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/// @title GameItems
/// @notice ERC-1155 holding fungible-ish in-game assets that NPC TBAs trade
///         between each other and with players. Item IDs are fixed at deploy
///         time so the Unity client can map id -> sprite/effect statically.
contract GameItems is ERC1155, Ownable {
    // ERC1155 does not require name/symbol in the standard,
    // but wallets (e.g. MetaMask), marketplaces (e.g. OpenSea),
    // and block explorers commonly read these fields for display purposes,
    // so we expose them manually.
    string public constant name   = "Arc NPC Items";
    string public constant symbol = "ANPCITEM";

    uint256 public constant MARKET_INTEL    = 1; // 市场情报 (consumable)
    uint256 public constant ENERGY_PACK     = 2; // 行为/算力能量
    uint256 public constant ACCESS_PASS     = 3; // 区域 / 服务通行证
    uint256 public constant RISK_REPORT     = 4; // 风控报告
    uint256 public constant SERVICE_VOUCHER = 5; // 服务券（可由 NPC 之间履约）

    /// @notice Collection-level metadata URI used by marketplaces such as OpenSea
    /// to display the collection cover image, description, and external links.
    string public contractURI;

    mapping(uint256 => string) private _names;
    mapping(address => bool)   public isMinter;

    event MinterUpdated(address indexed minter, bool allowed);

    error NotMinter();

    modifier onlyMinter() {
        if (!isMinter[msg.sender]) revert NotMinter();
        _;
    }

    constructor(address initialOwner, string memory baseUri)
        ERC1155(baseUri)
        Ownable(initialOwner)
    {
        isMinter[initialOwner] = true;
        emit MinterUpdated(initialOwner, true);

        _names[MARKET_INTEL]    = "MarketIntel";
        _names[ENERGY_PACK]     = "EnergyPack";
        _names[ACCESS_PASS]     = "AccessPass";
        _names[RISK_REPORT]     = "RiskReport";
        _names[SERVICE_VOUCHER] = "ServiceVoucher";
    }

    // ---------- Admin ----------
    function setMinter(address minter, bool allowed) external onlyOwner {
        isMinter[minter] = allowed;
        emit MinterUpdated(minter, allowed);
    }

    function setUri(string calldata newUri) external onlyOwner {
        _setURI(newUri);
    }

    function setContractURI(string calldata newContractURI) external onlyOwner {
        contractURI = newContractURI;
    }

    // ---------- Mint ----------
    function mint(address to, uint256 id, uint256 amount, bytes calldata data)
        external
        onlyMinter
    {
        _mint(to, id, amount, data);
    }

    function mintBatch(
        address to,
        uint256[] calldata ids,
        uint256[] calldata amounts,
        bytes calldata data
    ) external onlyMinter {
        _mintBatch(to, ids, amounts, data);
    }

    // ---------- Views ----------
    function nameOf(uint256 id) external view returns (string memory) {
        return _names[id];
    }
}
