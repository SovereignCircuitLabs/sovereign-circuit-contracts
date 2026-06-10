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

    // ---------- x402 Payment Wallet Binding ----------
    // Each NPC may bind an off-chain-controlled EOA used ONLY for x402 /
    // EIP-3009 payment signing. This wallet is NOT the TBA, NOT the NFT, and
    // is NOT derived from either — it is an operational payment account whose
    // private key lives in the off-chain x402 service. On NFT transfer the
    // binding is auto-revoked (wallet cleared, version bumped) so the old
    // operator's key cannot continue authorizing payments under the new owner.
    mapping(uint256 => address) public npcPaymentWallet;
    mapping(uint256 => uint64)  public npcPaymentVersion;

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

    /// @notice Emitted when an NFT owner binds (or re-binds / rotates) the
    ///         x402 payment wallet for an NPC. Does NOT bump version — version
    ///         tracks custody changes only. Off-chain services should treat
    ///         this event as authoritative for the current payment address.
    event NpcPaymentWalletBound(
        uint256 indexed tokenId,
        address indexed paymentWallet,
        address indexed boundBy,
        uint64 version
    );

    /// @notice Emitted on explicit owner-initiated clear (no version bump).
    event NpcPaymentWalletCleared(
        uint256 indexed tokenId,
        address indexed previousWallet,
        address indexed clearedBy,
        uint64 version
    );

    /// @notice Emitted on every NFT transfer / burn, regardless of whether a
    ///         wallet was bound. The version monotonically increments so
    ///         off-chain caches can detect stale state without joining against
    ///         ERC721 Transfer events.
    event NpcPaymentWalletReset(
        uint256 indexed tokenId,
        address indexed previousWallet,
        uint64 newVersion
    );

    // ---------- Errors ----------
    error NotMinter();
    error NotNftOwner();
    error InvalidRiskLevel();
    error InvalidPortfolioWeights();
    error InvalidTradeRange();
    error InvalidIntervals();
    error TokenDoesNotExist();
    error InvalidPaymentWallet();
    error PaymentWalletUnchanged();

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

    // ---------- Payment Wallet (x402 operator key) ----------

    /// @notice Bind / rotate the off-chain payment wallet for this NPC.
    /// @dev    The current NFT owner is the only authority. The wallet is an
    ///         EOA whose private key lives in the off-chain x402 service and
    ///         is used to sign EIP-3009 transferWithAuthorization payloads.
    ///         Re-binding is allowed (rotation); to fully revoke, call
    ///         `clearPaymentWallet`. Version is NOT incremented here — version
    ///         tracks NFT custody, not operator key churn.
    function bindPaymentWallet(uint256 tokenId, address wallet) external {
        address holder = _ownerOf(tokenId);
        if (holder == address(0)) revert TokenDoesNotExist();
        if (msg.sender != holder) revert NotNftOwner();
        if (wallet == address(0)) revert InvalidPaymentWallet();
        if (npcPaymentWallet[tokenId] == wallet) revert PaymentWalletUnchanged();

        npcPaymentWallet[tokenId] = wallet;
        emit NpcPaymentWalletBound(tokenId, wallet, holder, npcPaymentVersion[tokenId]);
    }

    /// @notice Explicit owner-side revoke. Off-chain service should observe
    ///         the cleared address and refuse to sign further x402 payments.
    function clearPaymentWallet(uint256 tokenId) external {
        address holder = _ownerOf(tokenId);
        if (holder == address(0)) revert TokenDoesNotExist();
        if (msg.sender != holder) revert NotNftOwner();

        address prev = npcPaymentWallet[tokenId];
        if (prev == address(0)) revert PaymentWalletUnchanged();

        delete npcPaymentWallet[tokenId];
        emit NpcPaymentWalletCleared(tokenId, prev, holder, npcPaymentVersion[tokenId]);
    }

    // ---------- ERC721 lifecycle hook ----------

    /// @dev OZ v5 unifies mint / transfer / burn into `_update`.
    /// When the NFT is transferred or burned:
    /// Clear the bound x402 payment wallet;
    /// Increment the version to invalidate old signatures.
    function _update(address to, uint256 tokenId, address auth)
        internal
        override
        returns (address from)
    {
        from = super._update(to, tokenId, auth);

        if (from != address(0)) {
            address prev = npcPaymentWallet[tokenId];
            uint64 newVersion;
            unchecked { newVersion = npcPaymentVersion[tokenId] + 1; }
            npcPaymentVersion[tokenId] = newVersion;

            if (prev != address(0)) {
                delete npcPaymentWallet[tokenId];
            }
            emit NpcPaymentWalletReset(tokenId, prev, newVersion);
        }
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

    /// @notice Atomic (wallet, version) read for off-chain x402 verification.
    ///         Off-chain check:
    ///           ecrecover(derive(privKey)) == wallet  &&  version == cachedVersion
    function getPaymentBinding(uint256 tokenId)
        external
        view
        returns (address wallet, uint64 version)
    {
        if (_ownerOf(tokenId) == address(0)) revert TokenDoesNotExist();
        return (npcPaymentWallet[tokenId], npcPaymentVersion[tokenId]);
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
