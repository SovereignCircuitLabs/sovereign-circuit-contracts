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

    uint256 public constant MINT_PRICE = 100_000; // 0.10 USDC (6 decimals)
    uint256 public constant NUM_TYPES = 5;

    IERC20 public immutable usdc;
    GameItems public immutable items;

    address public owner;
    IGatewayWallet public gateway; // Circle Gateway Wallet

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

    event GatewaySet(
        address indexed previousGateway,
        address indexed newGateway
    );
    event GatewayDeposited(address indexed gateway, uint256 amount);
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

    constructor(address _usdc, address _items, address _gateway) {
        require(_usdc != address(0), "Invalid USDC address");
        require(_items != address(0), "Invalid items address");
        require(_gateway != address(0), "Invalid gateway wallet address");

        usdc = IERC20(_usdc);
        items = GameItems(_items);
        gateway = IGatewayWallet(_gateway);
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

    /// @notice Pays MINT_PRICE USDC (caller must approve this contract first)
    ///         to randomly receive one of the 5 NFT types.
    ///         Returns the actual minted token id.
    ///         NOT via x402!
    function mintRandom() external returns (uint256 id) {
        usdc.safeTransferFrom(msg.sender, address(this), MINT_PRICE);

        id = _randomItemId();

        if (circulatingSupply[id] == 0) {
            activeTypeCount += 1;
        }
        circulatingSupply[id] += 1;

        items.mint(msg.sender, id, 1, "");

        emit ItemMinted(msg.sender, id, MINT_PRICE);
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

        emit ItemMinted(to, id, MINT_PRICE);
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

        items.safeTransferFrom(msg.sender, address(this), id, 1, "");

        circulatingSupply[id] -= 1;
        if (circulatingSupply[id] == 0) {
            activeTypeCount -= 1;
        }

        usdc.safeTransfer(msg.sender, price);

        emit ItemSold(msg.sender, id, price);
    }

    /// @notice Current buyback price for each `id`.
    ///         Formula:
    ///         price = poolBalance / (activeTypeCount * circulatingSupply[id])
    ///         Ensures that sum_over_types(supply * price) == poolBalance,
    ///         so the contract always remains fully solvent.
    function getSellPrice(uint256 id) public view returns (uint256) {
        uint256 supply = circulatingSupply[id];
        if (supply == 0 || activeTypeCount == 0) return 0;
        return usdc.balanceOf(address(this)) / (activeTypeCount * supply);
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

    /// @dev Note: uses pseudo-randomness based on block.prevrandao —
    ///      sufficient for low-value loot draws, but theoretically influenceable
    ///      by validators/miners. If high-value drops are introduced in the future,
    ///      consider replacing this with Chainlink VRF or a commit-reveal scheme.
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
