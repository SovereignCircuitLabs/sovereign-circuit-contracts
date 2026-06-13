// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {
    SafeERC20
} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {
    ERC1155Holder
} from "@openzeppelin/contracts/token/ERC1155/utils/ERC1155Holder.sol";
import {GameItems} from "./npc/GameItems.sol";
import {Npc6551Manager} from "./npc/Npc6551Manager.sol";

interface IGatewayWallet {
    function deposit(address token, uint256 value) external;
    function depositFor(
        address token,
        address depositor,
        uint256 value
    ) external;
    function initiateWithdrawal(address token, uint256 value) external;
    function withdraw(address token) external;

    function availableBalance(
        address token,
        address depositor
    ) external view returns (uint256);
    function withdrawableBalance(
        address token,
        address depositor
    ) external view returns (uint256);
    function withdrawingBalance(
        address token,
        address depositor
    ) external view returns (uint256);
    function totalBalance(
        address token,
        address depositor
    ) external view returns (uint256);
    function withdrawalBlock(
        address token,
        address depositor
    ) external view returns (uint256);
    function withdrawalDelay() external view returns (uint256);

    function addDelegate(address token, address delegate) external;
    function removeDelegate(address token, address delegate) external;
    function isAuthorizedForBalance(
        address token,
        address depositor,
        address addr
    ) external view returns (bool);
    function isTokenSupported(address token) external view returns (bool);
}

contract GamePayment is ERC1155Holder {
    using SafeERC20 for IERC20;

    // Lightweight dynamic AMM pricing (bonding curve, USDC has 6 decimals):
    //   buyPrice(id)  = BASELINE_PRICE + circulatingSupply[id] * PRICE_SLOPE
    //   sellPrice(id) = buyPrice(id) * SELL_SPREAD_BPS / BPS_DENOMINATOR
    uint256 public constant BASELINE_PRICE = 100_000; // 0.10 USDC: floor price when circulatingSupply == 0
    uint256 public constant PRICE_SLOPE = 5_000; // 0.005 USDC per unit of circulating supply
    uint256 public constant SELL_SPREAD_BPS = 9_500; // sell at 95% of buy price (5% spread)
    uint256 public constant BPS_DENOMINATOR = 10_000;

    uint256 public constant NUM_TYPES = 5;

    IERC20 public immutable usdc;
    GameItems public immutable items;

    address public owner;
    IGatewayWallet public gateway; // Circle Gateway Wallet
    Npc6551Manager public manager; // resolves NPC tokenId -> ERC-6551 TBA address

    // NFT token ids
    uint256[NUM_TYPES] public itemIds;
    // id => circulating supply (excluding the contract's own buyback inventory)
    mapping(uint256 => uint256) public circulatingSupply;
    // NFT whose circulatingSupply > 0
    uint256 public activeTypeCount;

    uint256 private _nonce;

    // ----------------------------- events -----------------------------

    event OwnershipTransferred(
        address indexed previousOwner,
        address indexed newOwner
    );
    event ItemMinted(
        address indexed buyer,
        uint256 indexed id,
        uint256 pricePaid
    );
    event ItemSold(
        address indexed seller,
        uint256 indexed id,
        uint256 priceReceived
    );

    event ManagerSet(
        address indexed previousManager,
        address indexed newManager
    );

    event GatewaySet(
        address indexed previousGateway,
        address indexed newGateway
    );
    event GatewayDeposited(address indexed gateway, uint256 amount);
    event RefundedToGateway(address indexed buyer, uint256 amount);
    event GatewayWithdrawalInitiated(address indexed gateway, uint256 amount);
    event GatewayWithdrawalCompleted(address indexed gateway);
    event GatewayDelegateAdded(
        address indexed gateway,
        address indexed delegate
    );
    event GatewayDelegateRemoved(
        address indexed gateway,
        address indexed delegate
    );

    // ----------------------------- modifiers -----------------------------

    modifier onlyOwner() {
        require(msg.sender == owner, "Not owner");
        _;
    }

    modifier gatewayConfigured() {
        require(address(gateway) != address(0), "Gateway not set");
        _;
    }

    // ----------------------------- constructor -----------------------------

    constructor(address _usdc, address _items, address _gateway, address _manager) {
        require(_usdc != address(0), "Invalid USDC address");
        require(_items != address(0), "Invalid items address");
        require(_gateway != address(0), "Invalid gateway wallet address");

        usdc = IERC20(_usdc);
        items = GameItems(_items);
        gateway = IGatewayWallet(_gateway);
        manager = Npc6551Manager(_manager);
        owner = msg.sender;

        itemIds[0] = items.MARKET_INTEL();
        itemIds[1] = items.ENERGY_PACK();
        itemIds[2] = items.ACCESS_PASS();
        itemIds[3] = items.RISK_REPORT();
        itemIds[4] = items.SERVICE_VOUCHER();

        emit OwnershipTransferred(address(0), msg.sender);
    }

    function transferOwnership(address newOwner) external onlyOwner {
        require(newOwner != address(0), "Invalid new owner");
        address old = owner;
        owner = newOwner;
        emit OwnershipTransferred(old, newOwner);
    }

    // ----------------------------- Loot Draw / Buyback -----------------------------

    /// @notice Rolls a random NFT type and charges the caller the current
    ///         bonding-curve buy price for that id.
    function mintRandom(uint256 maxPriceAllowed) external returns (uint256 id) {
        id = _randomItemId();

        uint256 price = getBuyPrice(id);
        require(price <= maxPriceAllowed, "Price exceeds max allowed");

        usdc.safeTransferFrom(msg.sender, address(this), price);

        if (circulatingSupply[id] == 0) {
            activeTypeCount += 1;
        }
        circulatingSupply[id] += 1;

        items.mint(msg.sender, id, 1, "");

        emit ItemMinted(msg.sender, id, price);
    }

    /// @notice Called by the trusted x402 relayer(server) after payment is verified.
    ///         Mints one random NFT type to the paid NPC/user address.
    function mintRandomX402(
        address to
    ) external onlyOwner returns (uint256 id) {
        require(to != address(0), "Invalid receiver");

        id = _randomItemId();

        if (circulatingSupply[id] == 0) {
            activeTypeCount += 1;
        }
        circulatingSupply[id] += 1;

        items.mint(to, id, 1, "");

        emit ItemMinted(to, id, BASELINE_PRICE);
    }

    /// @notice Called by the trusted x402 relayer(server) to mint a SPECIFIC
    ///         itemId to `to` after the off-chain x402 payment has been
    ///         verified and settled into the gateway.
    ///         Server-side flow:
    ///           1. read getBuyPrice(id) from chain
    ///           2. build an x402 payment requirement for that amount
    ///           3. verify & settle the user's USDC payment off-chain
    ///           4. call buyItemX402(to, id, paidAmount, maxPriceAllowed)
    function buyItemX402(
        address to,
        uint256 id,
        uint256 paidAmount,
        uint256 maxPriceAllowed
    ) external onlyOwner returns (uint256 price) {
        require(to != address(0), "Invalid receiver");
        require(_isManagedId(id), "Invalid id");

        price = getBuyPrice(id);
        require(price <= maxPriceAllowed, "Price exceeds max allowed");
        require(paidAmount >= price, "Paid amount below current price");

        if (circulatingSupply[id] == 0) {
            activeTypeCount += 1;
        }
        circulatingSupply[id] += 1;

        items.mint(to, id, 1, "");

        emit ItemMinted(to, id, price);
    }

    /// @notice Called by the trusted x402 relayer(server) to refund `amount`
    ///         USDC base units back into `buyer`'s Circle Gateway balance, used
    ///         when an order fails after the buyer's payment already settled
    ///         into this contract (e.g. the buyItemX402 mint reverted).
    /// @dev    Refunding via depositFor credits the buyer's Gateway available
    ///         balance directly — so the buyer can immediately fund the next
    ///         x402 payment or withdraw() back to their EOA, which fits the NPC
    ///         economy better than returning to the EOA. Pays out of the
    ///         contract's USDC pool, so callers must ensure the failed payment
    ///         actually landed here before refunding.
    function refundToGateway(
        address buyer,
        uint256 amount
    ) external onlyOwner gatewayConfigured {
        require(buyer != address(0), "Invalid buyer");
        require(amount > 0, "Invalid amount");
        require(
            usdc.balanceOf(address(this)) >= amount,
            "Insufficient contract USDC"
        );

        usdc.forceApprove(address(gateway), amount);
        gateway.depositFor(address(usdc), buyer, amount);

        emit RefundedToGateway(buyer, amount);
    }

    /// @notice Records that `amount` units of `id` entered circulation through
    ///         the NPC manager (items minted directly into an NPC's TBA).
    ///         Keeps the bonding-curve supply accounting in sync with these
    ///         off-curve mints so pricing and buyback stay consistent.
    /// @dev    Only callable by the configured manager — a contract cannot
    ///         mutate another contract's storage, so the manager must route
    ///         supply updates through here.
    function recordManagerMint(uint256 id, uint256 amount) external {
        require(msg.sender == address(manager), "Not manager");
        require(_isManagedId(id), "Invalid id");
        require(amount > 0, "Zero amount");

        if (circulatingSupply[id] == 0) {
            activeTypeCount += 1;
        }
        circulatingSupply[id] += amount;
    }

    /// @notice Sells one NFT back to the contract.
    ///         The caller must first call setApprovalForAll on GameItems for this contract.
    ///         The buyback price is calculated via getSellPrice(id).
    function sellItem(uint256 id) external returns (uint256 price) {
        require(_isManagedId(id), "Invalid id");
        require(circulatingSupply[id] > 0, "No circulating supply");

        price = getSellPrice(id);
        require(price > 0, "Zero sell price");
        require(
            usdc.balanceOf(address(this)) >= price,
            "Insufficient pool liquidity"
        );

        // msg.sender == TBA
        items.safeTransferFrom(msg.sender, address(this), id, 1, "");

        circulatingSupply[id] -= 1;
        if (circulatingSupply[id] == 0) {
            activeTypeCount -= 1;
        }

        usdc.safeTransfer(msg.sender, price);

        emit ItemSold(msg.sender, id, price);
    }

    /// @notice Current buy price for `id` on the bonding curve.
    ///         price grows linearly with circulating supply, so more popular
    ///         items become more expensive — the dynamic AMM-style behavior.
    function getBuyPrice(uint256 id) public view returns (uint256) {
        return BASELINE_PRICE + circulatingSupply[id] * PRICE_SLOPE;
    }

    /// @notice Buyback price for `id`. Fixed fraction (SELL_SPREAD_BPS) of the
    ///         live buy price — the spread is what keeps round-trip arbitrage
    ///         unprofitable for the chosen BASELINE/SLOPE configuration.
    function getSellPrice(uint256 id) public view returns (uint256) {
        return (getBuyPrice(id) * SELL_SPREAD_BPS) / BPS_DENOMINATOR;
    }

    function getAllBuyPrices()
        external
        view
        returns (uint256[NUM_TYPES] memory prices)
    {
        for (uint256 i = 0; i < NUM_TYPES; i++) {
            prices[i] = getBuyPrice(itemIds[i]);
        }
    }

    function getAllSellPrices()
        external
        view
        returns (uint256[NUM_TYPES] memory prices)
    {
        for (uint256 i = 0; i < NUM_TYPES; i++) {
            prices[i] = getSellPrice(itemIds[i]);
        }
    }

    function getContractBalance() external view returns (uint256) {
        return usdc.balanceOf(address(this));
    }

    function getItemIds() external view returns (uint256[NUM_TYPES] memory) {
        return itemIds;
    }

    // ----------------------------- NPC TBA item reads -----------------------------

    function setManager(address _manager) external onlyOwner {
        address old = address(manager);
        manager = Npc6551Manager(_manager);
        emit ManagerSet(old, _manager);
    }

    /// @notice Obtain the TBA address for an NPC tokenId.
    function npcTba(uint256 tokenId) public view returns (address) {
        require(address(manager) != address(0), "Manager not set");
        return manager.accountOf(tokenId);
    }

    /// @notice Balances held by `tba` for every managed item id.
    ///         `ids` and `balances` are one-to-one aligned.
    function getTbaItemBalances(
        address tba
    )
        public
        view
        returns (
            uint256[NUM_TYPES] memory ids,
            uint256[NUM_TYPES] memory balances
        )
    {
        address[] memory accounts = new address[](NUM_TYPES);
        uint256[] memory idList = new uint256[](NUM_TYPES);
        for (uint256 i = 0; i < NUM_TYPES; i++) {
            ids[i] = itemIds[i];
            accounts[i] = tba;
            idList[i] = itemIds[i];
        }

        uint256[] memory bals = items.balanceOfBatch(accounts, idList);
        for (uint256 i = 0; i < NUM_TYPES; i++) {
            balances[i] = bals[i];
        }
    }

    /// @notice Returns the TBA address plus all the NFT ids it actually holds and their balances.
    function getTbaOwnedItems(
        address tba
    ) public view returns (uint256[] memory ids, uint256[] memory balances) {
        (
            uint256[NUM_TYPES] memory allIds,
            uint256[NUM_TYPES] memory allBalances
        ) = getTbaItemBalances(tba);

        uint256 owned;
        for (uint256 i = 0; i < NUM_TYPES; i++) {
            if (allBalances[i] > 0) owned++;
        }

        ids = new uint256[](owned);
        balances = new uint256[](owned);
        uint256 j;
        for (uint256 i = 0; i < NUM_TYPES; i++) {
            if (allBalances[i] > 0) {
                ids[j] = allIds[i];
                balances[j] = allBalances[i];
                j++;
            }
        }
    }

    /// @notice Resolve an NPC tokenId to its TBA and return that TBA's balance
    ///         for every managed item id (aligned with `itemIds`).
    function getNpcTbaItemBalances(
        uint256 tokenId
    )
        external
        view
        returns (
            address tba,
            uint256[NUM_TYPES] memory ids,
            uint256[NUM_TYPES] memory balances
        )
    {
        tba = npcTba(tokenId);
        (ids, balances) = getTbaItemBalances(tba);
    }

    /// @notice Resolve an NPC tokenId to its TBA and return only the item ids
    ///         it holds (balance > 0) together with those balances.
    function getNpcTbaOwnedItems(
        uint256 tokenId
    )
        external
        view
        returns (address tba, uint256[] memory ids, uint256[] memory balances)
    {
        tba = npcTba(tokenId);
        (ids, balances) = getTbaOwnedItems(tba);
    }

    function _randomItemId() private returns (uint256) {
        _nonce += 1;
        uint256 idx = uint256(
            keccak256(
                abi.encode(
                    block.prevrandao,
                    block.timestamp,
                    msg.sender,
                    _nonce
                )
            )
        ) % NUM_TYPES;
        return itemIds[idx];
    }

    function _isManagedId(uint256 id) private view returns (bool) {
        for (uint256 i = 0; i < NUM_TYPES; i++) {
            if (itemIds[i] == id) return true;
        }
        return false;
    }

    // ----------------------------- Gateway Wallet -----------------------------

    function setGateway(address _gateway) external onlyOwner {
        address old = address(gateway);
        gateway = IGatewayWallet(_gateway);
        emit GatewaySet(old, _gateway);
    }

    function depositToGateway(
        uint256 amount
    ) external onlyOwner gatewayConfigured {
        require(amount > 0, "Invalid amount");
        require(
            usdc.balanceOf(address(this)) >= amount,
            "Insufficient contract USDC"
        );

        usdc.forceApprove(address(gateway), amount);
        gateway.deposit(address(usdc), amount);

        emit GatewayDeposited(address(gateway), amount);
    }

    function initiateGatewayWithdrawal(
        uint256 amount
    ) external onlyOwner gatewayConfigured {
        require(amount > 0, "Invalid amount");
        gateway.initiateWithdrawal(address(usdc), amount);
        emit GatewayWithdrawalInitiated(address(gateway), amount);
    }

    function completeGatewayWithdrawal() external onlyOwner gatewayConfigured {
        gateway.withdraw(address(usdc));
        emit GatewayWithdrawalCompleted(address(gateway));
    }

    function addGatewayDelegate(
        address delegate
    ) external onlyOwner gatewayConfigured {
        require(delegate != address(0), "Invalid delegate");
        gateway.addDelegate(address(usdc), delegate);
        emit GatewayDelegateAdded(address(gateway), delegate);
    }

    function removeGatewayDelegate(
        address delegate
    ) external onlyOwner gatewayConfigured {
        gateway.removeDelegate(address(usdc), delegate);
        emit GatewayDelegateRemoved(address(gateway), delegate);
    }

    function gatewayAvailableBalance() external view returns (uint256) {
        if (address(gateway) == address(0)) return 0;
        return gateway.availableBalance(address(usdc), address(this));
    }

    function gatewayWithdrawableBalance() external view returns (uint256) {
        if (address(gateway) == address(0)) return 0;
        return gateway.withdrawableBalance(address(usdc), address(this));
    }

    function gatewayWithdrawingBalance() external view returns (uint256) {
        if (address(gateway) == address(0)) return 0;
        return gateway.withdrawingBalance(address(usdc), address(this));
    }

    function gatewayTotalBalance() external view returns (uint256) {
        if (address(gateway) == address(0)) return 0;
        return gateway.totalBalance(address(usdc), address(this));
    }

    function gatewayWithdrawalBlock() external view returns (uint256) {
        if (address(gateway) == address(0)) return 0;
        return gateway.withdrawalBlock(address(usdc), address(this));
    }

    function gatewayWithdrawalDelay() external view returns (uint256) {
        if (address(gateway) == address(0)) return 0;
        return gateway.withdrawalDelay();
    }

    function isGatewayAuthorized(address addr) external view returns (bool) {
        if (address(gateway) == address(0)) return false;
        return
            gateway.isAuthorizedForBalance(address(usdc), address(this), addr);
    }

    function isGatewayTokenSupported() external view returns (bool) {
        if (address(gateway) == address(0)) return false;
        return gateway.isTokenSupported(address(usdc));
    }

    // ----------------------------- fallback -----------------------------

    receive() external payable {
        revert("Native token not accepted");
    }

    fallback() external payable {
        revert("Native token not accepted");
    }
}
