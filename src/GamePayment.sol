// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

contract GamePayment {
    mapping(address => uint256) public balances; // 记录每个用户存入合约的原生 USDC 数量

    event PlayerPaid(
        address indexed from,
        address indexed to,
        uint256 amount,
        string reason
    );
    event Deposited(address indexed from, uint256 amount);
    event Withdrawn(address indexed to, uint256 amount);

    function payPlayer(
        address to,
        uint256 amount,
        string calldata reason
    ) external {
        require(to != address(0), "Invalid receiver");
        require(amount > 0, "Invalid amount");
        require(balances[msg.sender] >= amount, "Insufficient balance");

        balances[msg.sender] -= amount;

        (bool success, ) = to.call{value: amount}("");
        require(success, "Transfer failed");

        emit PlayerPaid(msg.sender, to, amount, reason);
    }

    function deposit() external payable {
        require(msg.value > 0, "Invalid amount");

        balances[msg.sender] += msg.value;

        emit Deposited(msg.sender, msg.value);
    }

    function withdraw(uint256 amount) external {
        require(amount > 0, "Invalid amount");
        require(balances[msg.sender] >= amount, "Insufficient balance");

        balances[msg.sender] -= amount;

        (bool success, ) = msg.sender.call{value: amount}("");
        require(success, "Transfer failed");

        emit Withdrawn(msg.sender, amount);
    }

    function getBalance(address account) external view returns (uint256) {
        return balances[account];
    }

    function getContractBalance() external view returns (uint256) {
        return address(this).balance;
    }

    receive() external payable {
        require(msg.value > 0, "Invalid amount");

        balances[msg.sender] += msg.value;

        emit Deposited(msg.sender, msg.value);
    }

    fallback() external payable {
        require(msg.value > 0, "Invalid amount");

        balances[msg.sender] += msg.value;

        emit Deposited(msg.sender, msg.value);
    }
}
