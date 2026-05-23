// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {
    SafeERC20
} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

contract GamePayment {
    using SafeERC20 for IERC20;

    IERC20 public immutable usdc;
    address public owner;

    mapping(address => uint256) public balances; // 记录每个用户存入合约的 USDC 数量（6 decimals 最小单位）

    event PlayerPaid(
        address indexed from,
        address indexed to,
        uint256 amount,
        string reason
    );
    event Deposited(address indexed from, uint256 amount);
    event Withdrawn(address indexed to, uint256 amount);
    event OwnershipTransferred(
        address indexed previousOwner,
        address indexed newOwner
    );

    modifier onlyOwner() {
        require(msg.sender == owner, "Not owner");
        _;
    }

    constructor(address _usdc) {
        require(_usdc != address(0), "Invalid USDC address");
        usdc = IERC20(_usdc);
        owner = msg.sender;
        emit OwnershipTransferred(address(0), msg.sender);
    }

    function transferOwnership(address newOwner) external onlyOwner {
        require(newOwner != address(0), "Invalid new owner");
        address old = owner;
        owner = newOwner;
        emit OwnershipTransferred(old, newOwner);
    }

    function payPlayer(
        address to,
        uint256 amount,
        string calldata reason
    ) external {
        require(to != address(0), "Invalid receiver");
        require(amount > 0, "Invalid amount");
        require(balances[msg.sender] >= amount, "Insufficient balance");

        balances[msg.sender] -= amount;

        usdc.safeTransfer(to, amount);

        emit PlayerPaid(msg.sender, to, amount, reason);
    }

    function deposit(uint256 amount) external {
        require(amount > 0, "Invalid amount");

        usdc.safeTransferFrom(msg.sender, address(this), amount);
        balances[msg.sender] += amount;

        emit Deposited(msg.sender, amount);
    }

    function withdraw(uint256 amount) external {
        require(amount > 0, "Invalid amount");
        require(balances[msg.sender] >= amount, "Insufficient balance");

        balances[msg.sender] -= amount;

        usdc.safeTransfer(msg.sender, amount);

        emit Withdrawn(msg.sender, amount);
    }

    function getBalance(address account) external view returns (uint256) {
        return balances[account];
    }

    function getContractBalance() external view returns (uint256) {
        return usdc.balanceOf(address(this));
    }

    receive() external payable {
        revert("Native token not accepted");
    }

    fallback() external payable {
        revert("Native token not accepted");
    }
}
