// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {ERC721URIStorage} from "@openzeppelin/contracts/token/ERC721/extensions/ERC721URIStorage.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/// @title NpcCharacter
/// @notice ERC-721 representing an Arc AI NPC's on-chain identity AND its
///         persisted economic configuration.
///
///         The PortfolioConfig sub-struct mirrors the Unity-side
///         `NpcPortfolioConfig` class 1:1, with these unit conversions:
///           Unity float weight (0..1)  → uint16 basis points (0..10000)
///           Unity float USDC           → uint64 USDC smallest unit (6 decimals)
///           Unity float seconds        → uint32 seconds
///         => The chain is the source of truth for the NPC's strategy params;
///         Unity reads them on spawn and writes back via updatePortfolio when
///         the player retunes the NPC.
contract NpcCharacter is ERC721URIStorage, Ownable {
    enum Archetype {
        ConservativeSaver,
        BalancedTrader,
        AggressiveSpeculator
    }

    /// @notice Mirrors Unity `NpcPortfolioConfig`. See header comment for unit map.
    struct PortfolioConfig {
        // [Budgets] — three weights MUST sum to BPS_DENOMINATOR (10000).
        uint16 livingNeedsWeightBps;        // Unity: livingNeedsWeight
        uint16 reserveWeightBps;            // Unity: reserveWeight
        uint16 tradingWeightBps;            // Unity: tradingWeight

        // [Thresholds]
        uint64 minimumLivingBudgetUSDC;     // Unity: minimumLivingBudgetUSDC  (6-dec units)
        uint64 minimumReserveBudgetUSDC;    // Unity: minimumReserveBudgetUSDC (6-dec units)
        uint32 rebalanceIntervalSeconds;    // Unity: rebalanceInterval
        uint32 chainActionCooldownSeconds;  // Unity: chainActionCooldown

        // [Trade Size] — minTradeUSDC MUST be <= maxTradeUSDC.
        uint64 minTradeUSDC;                // Unity: minTradeUSDC  (6-dec units)
        uint64 maxTradeUSDC;                // Unity: maxTradeUSDC  (6-dec units)
    }

    struct NpcData {
        // Identity
        string npcName;
        string metadataURI;
        Archetype archetype;
        uint8  riskLevel;    // 1..10
        uint16 level;
        uint32 reputation;
        // Strategy (canonical mirror of Unity NpcPortfolioConfig)
        PortfolioConfig portfolio;
    }

    uint16 public constant BPS_DENOMINATOR = 10000;

    uint256 public nextTokenId = 1;
    mapping(uint256 => NpcData) private _npcData;
    mapping(address => bool) public isMinter;

    // ---------- Events ----------
    event NpcMinted(
        uint256 indexed tokenId,
        address indexed to,
        string npcName,
        Archetype archetype,
        uint8 riskLevel
    );
    event NpcAttributesUpdated(
        uint256 indexed tokenId,
        uint16 level,
        uint32 reputation
    );
    event NpcPortfolioUpdated(
        uint256 indexed tokenId,
        PortfolioConfig portfolio
    );
    event MinterUpdated(address indexed minter, bool allowed);

    // ---------- Errors ----------
    error NotMinter();
    error NotNftOwner();
    error InvalidRiskLevel();
    error InvalidPortfolioWeights();
    error InvalidTradeRange();
    error InvalidIntervals();
    error TokenDoesNotExist();

    modifier onlyMinter() {
        if (!isMinter[msg.sender]) revert NotMinter();
        _;
    }

    constructor(address initialOwner)
        ERC721("Arc NPC Character", "ANPC")
        Ownable(initialOwner)
    {
        isMinter[initialOwner] = true;
        emit MinterUpdated(initialOwner, true);
    }

    // ---------- Admin ----------
    function setMinter(address minter, bool allowed) external onlyOwner {
        isMinter[minter] = allowed;
        emit MinterUpdated(minter, allowed);
    }

    // ---------- Mint / update ----------
    function mintNpc(address to, NpcData calldata data)
        external
        onlyMinter
        returns (uint256 tokenId)
    {
        if (data.riskLevel == 0 || data.riskLevel > 10) {
            revert InvalidRiskLevel();
        }
        _validatePortfolio(data.portfolio);

        tokenId = nextTokenId++;
        _npcData[tokenId] = data;
        _safeMint(to, tokenId);
        if (bytes(data.metadataURI).length > 0) {
            _setTokenURI(tokenId, data.metadataURI);
        }
        emit NpcMinted(tokenId, to, data.npcName, data.archetype, data.riskLevel);
        emit NpcPortfolioUpdated(tokenId, data.portfolio);
    }

    /// @notice Minter-side updates for live attributes (level / reputation).
    ///         The NPC's *AI behavior* is driven off-chain by Unity + agent
    ///         code; we only persist the canonical state here.
    function updateAttributes(uint256 tokenId, uint16 level, uint32 reputation)
        external
        onlyMinter
    {
        if (_ownerOf(tokenId) == address(0)) revert TokenDoesNotExist();
        NpcData storage d = _npcData[tokenId];
        d.level = level;
        d.reputation = reputation;
        emit NpcAttributesUpdated(tokenId, level, reputation);
    }

    /// @notice NFT-owner self-service tuning of the NPC's strategy parameters.
    ///         The owner is whoever currently holds the NPC NFT — buying the
    ///         NFT on a marketplace transfers strategy authority to the buyer.
    function updatePortfolio(uint256 tokenId, PortfolioConfig calldata p)
        external
    {
        address holder = _ownerOf(tokenId);
        if (holder == address(0)) revert TokenDoesNotExist();
        if (msg.sender != holder) revert NotNftOwner();

        _validatePortfolio(p);
        _npcData[tokenId].portfolio = p;
        emit NpcPortfolioUpdated(tokenId, p);
    }

    function setMetadataURI(uint256 tokenId, string calldata uri)
        external
        onlyMinter
    {
        if (_ownerOf(tokenId) == address(0)) revert TokenDoesNotExist();
        _npcData[tokenId].metadataURI = uri;
        _setTokenURI(tokenId, uri);
    }

    // ---------- Views ----------
    function getNpc(uint256 tokenId) external view returns (NpcData memory) {
        if (_ownerOf(tokenId) == address(0)) revert TokenDoesNotExist();
        return _npcData[tokenId];
    }

    function getPortfolio(uint256 tokenId)
        external
        view
        returns (PortfolioConfig memory)
    {
        if (_ownerOf(tokenId) == address(0)) revert TokenDoesNotExist();
        return _npcData[tokenId].portfolio;
    }

    function exists(uint256 tokenId) external view returns (bool) {
        return _ownerOf(tokenId) != address(0);
    }

    // ---------- Internal ----------
    function _validatePortfolio(PortfolioConfig memory p) internal pure {
        // Use uint256 for the sum to avoid uint16 overflow corner cases.
        uint256 sum = uint256(p.livingNeedsWeightBps)
                    + uint256(p.reserveWeightBps)
                    + uint256(p.tradingWeightBps);
        if (sum != BPS_DENOMINATOR) revert InvalidPortfolioWeights();

        if (p.minTradeUSDC > p.maxTradeUSDC) revert InvalidTradeRange();

        if (p.rebalanceIntervalSeconds == 0 || p.chainActionCooldownSeconds == 0) {
            revert InvalidIntervals();
        }
    }
}
