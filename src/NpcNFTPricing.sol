// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {GamePayment} from "./GamePayment.sol";
import {NpcCharacter} from "./npc/NpcCharacter.sol";

/// @title NpcNFTPricing
/// @notice Dynamic pricing module for NPC ERC-721s. It reads each NPC's ERC-6551
///         TBA item balances, TBA USDC cash, and NPC archetype, then applies an
///         AMM-inspired scarcity multiplier configured per archetype class.
contract NpcNFTPricing {
    uint256 public constant BPS = 10_000;
    uint256 private constant NPC_CLASS_OFFSET = 1;

    GamePayment public immutable gamePayment;
    NpcCharacter public immutable npcCharacter;
    IERC20 public immutable usdc;

    address public owner;
    address public authorizedMarket;

    struct NpcClassMarket {
        uint256 totalSupply;
        uint256 listedSupply;
        uint256 virtualLiquidity;
        uint256 basePrice;
        uint256 maxMultiplierBps;
        uint256 scarcityWeightBps;
        bool exists;
    }

    mapping(uint256 => NpcClassMarket) public classMarkets;

    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);
    event AuthorizedMarketSet(address indexed previousMarket, address indexed newMarket);
    event ClassMarketUpdated(
        uint256 indexed classId,
        uint256 totalSupply,
        uint256 listedSupply,
        uint256 basePrice
    );
    event ListedSupplyUpdated(uint256 indexed classId, uint256 listedSupply);

    modifier onlyOwner() {
        require(msg.sender == owner, "Not owner");
        _;
    }

    modifier onlyOwnerOrAuthorizedMarket() {
        require(msg.sender == owner || msg.sender == authorizedMarket, "Not authorized");
        _;
    }

    constructor(address _gamePayment, address _npcCharacter, address _usdc) {
        require(_gamePayment != address(0), "Invalid GamePayment");
        require(_npcCharacter != address(0), "Invalid NPC");
        require(_usdc != address(0), "Invalid USDC");

        GamePayment payment = GamePayment(payable(_gamePayment));
        require(address(payment.usdc()) == _usdc, "USDC mismatch");

        gamePayment = payment;
        npcCharacter = NpcCharacter(_npcCharacter);
        usdc = IERC20(_usdc);
        owner = msg.sender;

        emit OwnershipTransferred(address(0), msg.sender);
    }

    function transferOwnership(address newOwner) external onlyOwner {
        require(newOwner != address(0), "Invalid new owner");

        address oldOwner = owner;
        owner = newOwner;

        emit OwnershipTransferred(oldOwner, newOwner);
    }

    function setAuthorizedMarket(address market) external onlyOwner {
        address oldMarket = authorizedMarket;
        authorizedMarket = market;

        emit AuthorizedMarketSet(oldMarket, market);
    }

    function setClassMarket(
        uint256 classId,
        uint256 totalSupply,
        uint256 listedSupply,
        uint256 virtualLiquidity,
        uint256 basePrice,
        uint256 maxMultiplierBps,
        uint256 scarcityWeightBps
    ) external onlyOwner {
        require(classId != 0, "Invalid class");
        require(totalSupply > 0, "Invalid total supply");
        require(listedSupply <= totalSupply, "Listed exceeds total");
        require(virtualLiquidity > 0, "Invalid virtual liquidity");
        require(maxMultiplierBps >= BPS, "Invalid max multiplier");
        require(scarcityWeightBps <= BPS, "Invalid scarcity weight");

        classMarkets[classId] = NpcClassMarket({
            totalSupply: totalSupply,
            listedSupply: listedSupply,
            virtualLiquidity: virtualLiquidity,
            basePrice: basePrice,
            maxMultiplierBps: maxMultiplierBps,
            scarcityWeightBps: scarcityWeightBps,
            exists: true
        });

        emit ClassMarketUpdated(classId, totalSupply, listedSupply, basePrice);
        emit ListedSupplyUpdated(classId, listedSupply);
    }

    function setListedSupply(uint256 classId, uint256 listedSupply) external onlyOwnerOrAuthorizedMarket {
        NpcClassMarket storage market = _requireClassMarket(classId);
        require(listedSupply <= market.totalSupply, "Listed exceeds total");

        market.listedSupply = listedSupply;

        emit ListedSupplyUpdated(classId, listedSupply);
    }

    function increaseListedSupply(uint256 classId, uint256 amount) external onlyOwnerOrAuthorizedMarket {
        NpcClassMarket storage market = _requireClassMarket(classId);
        require(market.listedSupply + amount <= market.totalSupply, "Listed exceeds total");

        market.listedSupply += amount;

        emit ListedSupplyUpdated(classId, market.listedSupply);
    }

    function decreaseListedSupply(uint256 classId, uint256 amount) external onlyOwnerOrAuthorizedMarket {
        NpcClassMarket storage market = _requireClassMarket(classId);
        require(market.listedSupply >= amount, "Listed below zero");

        market.listedSupply -= amount;

        emit ListedSupplyUpdated(classId, market.listedSupply);
    }

    function getNpcClassId(uint256 tokenId) public view returns (uint256) {
        NpcCharacter.NpcData memory npc = npcCharacter.getNpc(tokenId);
        return uint256(npc.archetype) + NPC_CLASS_OFFSET;
    }

    function getNpcTbaTotalValue(uint256 tokenId) public view returns (uint256) {
        (, , , uint256 tbaTotalValue) = getNpcTbaValueBreakdown(tokenId);
        return tbaTotalValue;
    }

    function getNpcTbaValueBreakdown(uint256 tokenId)
        public
        view
        returns (address tba, uint256 itemValue, uint256 cashValue, uint256 tbaTotalValue)
    {
        tba = gamePayment.npcTba(tokenId);
        (, itemValue) = getNpcTbaItemValue(tokenId);
        cashValue = usdc.balanceOf(tba);
        tbaTotalValue = itemValue + cashValue;
    }

    function getNpcTbaItemValue(uint256 tokenId) public view returns (address tba, uint256 itemValue) {
        uint256[5] memory ids;
        uint256[5] memory balances;

        (tba, ids, balances) = gamePayment.getNpcTbaItemBalances(tokenId);

        for (uint256 i = 0; i < ids.length; i++) {
            if (balances[i] > 0) {
                itemValue += balances[i] * gamePayment.getSellPrice(ids[i]);
            }
        }
    }

    function getScarcityMultiplierBps(uint256 classId) public view returns (uint256) {
        NpcClassMarket memory market = classMarkets[classId];
        require(classId != 0, "Invalid class");
        require(market.exists, "Class market not set");

        uint256 rawMultiplierBps =
            ((market.totalSupply + market.virtualLiquidity) * BPS) / (market.listedSupply + market.virtualLiquidity);
        uint256 weightedMultiplierBps =
            BPS + ((rawMultiplierBps - BPS) * market.scarcityWeightBps) / BPS;

        if (weightedMultiplierBps > market.maxMultiplierBps) {
            return market.maxMultiplierBps;
        }

        return weightedMultiplierBps;
    }

    function quoteNpcPrice(uint256 tokenId)
        external
        view
        returns (uint256 price, uint256 tbaTotalValue, uint256 scarcityMultiplierBps)
    {
        uint256 classId = getNpcClassId(tokenId);
        NpcClassMarket memory market = classMarkets[classId];
        require(market.exists, "Class market not set");

        tbaTotalValue = getNpcTbaTotalValue(tokenId);
        scarcityMultiplierBps = getScarcityMultiplierBps(classId);
        price = ((market.basePrice + tbaTotalValue) * scarcityMultiplierBps) / BPS;
    }

    function _requireClassMarket(uint256 classId) private view returns (NpcClassMarket storage market) {
        require(classId != 0, "Invalid class");
        market = classMarkets[classId];
        require(market.exists, "Class market not set");
    }
}
