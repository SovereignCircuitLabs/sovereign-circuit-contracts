// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC6551Registry} from "./interfaces/IERC6551Registry.sol";

/// @title ERC6551Registry
/// @notice Minimal, canonical-compatible registry for EIP-6551 token-bound accounts.
/// @dev    The deployed account is an ERC-1167 minimal proxy with 128 bytes of
///         immutable arguments appended (salt, chainId, tokenContract, tokenId).
///         The address derivation matches the canonical singleton registry, so
///         redeploying this contract on a new chain with the *same* account
///         implementation reproduces the same TBA address per (chainId, NFT).
contract ERC6551Registry is IERC6551Registry {
    /// @inheritdoc IERC6551Registry
    function createAccount(
        address implementation,
        bytes32 salt,
        uint256 chainId,
        address tokenContract,
        uint256 tokenId
    ) external returns (address) {
        bytes memory code = _creationCode(
            implementation,
            salt,
            chainId,
            tokenContract,
            tokenId
        );
        address computed = _computeAddress(salt, keccak256(code));

        // Idempotent: if already deployed, just return the address.
        if (computed.code.length != 0) {
            return computed;
        }

        emit ERC6551AccountCreated(
            computed,
            implementation,
            salt,
            chainId,
            tokenContract,
            tokenId
        );

        address deployed;
        assembly {
            deployed := create2(0, add(code, 0x20), mload(code), salt)
        }
        if (deployed == address(0)) revert AccountCreationFailed();
        return deployed;
    }

    /// @inheritdoc IERC6551Registry
    function account(
        address implementation,
        bytes32 salt,
        uint256 chainId,
        address tokenContract,
        uint256 tokenId
    ) external view returns (address) {
        bytes memory code = _creationCode(
            implementation,
            salt,
            chainId,
            tokenContract,
            tokenId
        );
        return _computeAddress(salt, keccak256(code));
    }

    function _computeAddress(bytes32 salt, bytes32 bytecodeHash)
        internal
        view
        returns (address)
    {
        return
            address(
                uint160(
                    uint256(
                        keccak256(
                            abi.encodePacked(
                                bytes1(0xff),
                                address(this),
                                salt,
                                bytecodeHash
                            )
                        )
                    )
                )
            );
    }

    /// @dev EIP-6551 canonical creation code:
    ///      `0x3d60ad80600a3d3981f3`              (10B deploy prefix; returns next 0xad bytes)
    ///      `0x363d3d373d3d3d363d73<impl>5af43d82803e903d91602b57fd5bf3`
    ///                                            (ERC-1167 minimal proxy runtime, 45B)
    ///      `<salt(32)><chainId(32)><tokenContract(32)><tokenId(32)>`
    ///                                            (128B immutable args, readable via EXTCODECOPY @ 0x2d)
    function _creationCode(
        address implementation,
        bytes32 salt,
        uint256 chainId,
        address tokenContract,
        uint256 tokenId
    ) internal pure returns (bytes memory) {
        return
            abi.encodePacked(
                hex"3d60ad80600a3d3981f3363d3d373d3d3d363d73",
                implementation,
                hex"5af43d82803e903d91602b57fd5bf3",
                salt,
                chainId,
                uint256(uint160(tokenContract)),
                tokenId
            );
    }
}
