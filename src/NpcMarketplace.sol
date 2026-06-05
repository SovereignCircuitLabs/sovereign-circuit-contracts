// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {NpcCharacter} from "./npc/NpcCharacter.sol";
import {NpcNFTPricing} from "./NpcNFTPricing.sol";

/// @title NpcMarketplace
/// @notice Non-custodial marketplace for NPC ERC-721s. Listings keep NFTs in
///         seller wallets; purchases transfer USDC to the seller and then move
///         the NPC NFT to the buyer. ERC-6551 accounts are never called here.
contract NpcMarketplace {
    using SafeERC20 for IERC20;

    IERC20 public immutable usdc;
    NpcCharacter public immutable npcCharacter;
    NpcNFTPricing public immutable pricing;

    uint256 private _locked = 1;

    struct Listing {
        address seller;
        uint256 minPrice;
        bool active;
    }

    mapping(uint256 => Listing) public listings;

    event NpcListed(uint256 indexed tokenId, address indexed seller, uint256 minPrice);
    event NpcListingCancelled(uint256 indexed tokenId, address indexed seller);
    event StaleListingCleared(uint256 indexed tokenId, address indexed seller);
    event NpcPurchased(
        uint256 indexed tokenId,
        address indexed seller,
        address indexed buyer,
        uint256 price,
        uint256 tbaTotalValue,
        uint256 scarcityMultiplierBps
    );

    modifier nonReentrant() {
        require(_locked == 1, "Reentrant");
        _locked = 2;
        _;
        _locked = 1;
    }

    constructor(address _npcCharacter, address _pricing, address _usdc) {
        require(_npcCharacter != address(0), "Invalid NPC");
        require(_pricing != address(0), "Invalid pricing");
        require(_usdc != address(0), "Invalid USDC");

        NpcNFTPricing pricingModule = NpcNFTPricing(_pricing);
        require(address(pricingModule.npcCharacter()) == _npcCharacter, "NPC mismatch");
        require(address(pricingModule.usdc()) == _usdc, "USDC mismatch");

        npcCharacter = NpcCharacter(_npcCharacter);
        pricing = pricingModule;
        usdc = IERC20(_usdc);
    }

    function listNpc(uint256 tokenId, uint256 minPrice) external nonReentrant {
        require(!listings[tokenId].active, "Already listed");

        address seller = npcCharacter.ownerOf(tokenId);
        require(seller == msg.sender, "Not NFT owner");
        require(_isMarketplaceApproved(tokenId, seller), "Marketplace not approved");

        listings[tokenId] = Listing({seller: seller, minPrice: minPrice, active: true});

        uint256 classId = pricing.getNpcClassId(tokenId);
        pricing.increaseListedSupply(classId, 1);

        emit NpcListed(tokenId, seller, minPrice);
    }

    function cancelListing(uint256 tokenId) external nonReentrant {
        Listing memory listing = listings[tokenId];
        require(listing.active, "Not listed");

        address currentOwner = npcCharacter.ownerOf(tokenId);
        require(msg.sender == listing.seller || msg.sender == currentOwner, "Not listing owner");

        delete listings[tokenId];

        uint256 classId = pricing.getNpcClassId(tokenId);
        pricing.decreaseListedSupply(classId, 1);

        emit NpcListingCancelled(tokenId, listing.seller);
    }

    function clearStaleListing(uint256 tokenId) external nonReentrant {
        Listing memory listing = listings[tokenId];
        require(listing.active, "Not listed");

        address currentOwner = npcCharacter.ownerOf(tokenId);
        bool stale = currentOwner != listing.seller || !_isMarketplaceApproved(tokenId, listing.seller);
        require(stale, "Listing still valid");

        delete listings[tokenId];

        uint256 classId = pricing.getNpcClassId(tokenId);
        pricing.decreaseListedSupply(classId, 1);

        emit StaleListingCleared(tokenId, listing.seller);
    }

    function buyNpc(uint256 tokenId, uint256 maxPrice) external nonReentrant {
        Listing memory listing = listings[tokenId];
        require(listing.active, "Not listed");

        address seller = npcCharacter.ownerOf(tokenId);
        require(seller == listing.seller, "Seller no longer owner");
        require(seller != msg.sender, "Cannot buy own NPC");
        require(_isMarketplaceApproved(tokenId, seller), "Marketplace not approved");

        (uint256 price, uint256 tbaTotalValue, uint256 scarcityMultiplierBps) = pricing.quoteNpcPrice(tokenId);
        require(price >= listing.minPrice, "Price below seller minimum");
        require(price <= maxPrice, "Price exceeds max");

        delete listings[tokenId];

        uint256 classId = pricing.getNpcClassId(tokenId);
        pricing.decreaseListedSupply(classId, 1);

        usdc.safeTransferFrom(msg.sender, seller, price);
        npcCharacter.safeTransferFrom(seller, msg.sender, tokenId);

        emit NpcPurchased(tokenId, seller, msg.sender, price, tbaTotalValue, scarcityMultiplierBps);
    }

    function getListing(uint256 tokenId) external view returns (address seller, uint256 minPrice, bool active) {
        Listing memory listing = listings[tokenId];
        return (listing.seller, listing.minPrice, listing.active);
    }

    function _isMarketplaceApproved(uint256 tokenId, address seller) private view returns (bool) {
        return
            npcCharacter.getApproved(tokenId) == address(this)
                || npcCharacter.isApprovedForAll(seller, address(this));
    }
}
