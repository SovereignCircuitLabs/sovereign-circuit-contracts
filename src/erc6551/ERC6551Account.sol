// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import {IERC1155Receiver} from "@openzeppelin/contracts/token/ERC1155/IERC1155Receiver.sol";
import {IERC1271} from "@openzeppelin/contracts/interfaces/IERC1271.sol";
import {SignatureChecker} from "@openzeppelin/contracts/utils/cryptography/SignatureChecker.sol";

import {IERC6551Account} from "./interfaces/IERC6551Account.sol";
import {IERC6551Executable} from "./interfaces/IERC6551Executable.sol";

/// @title ERC6551Account
/// @notice Token-bound account: control follows the bound ERC-721 token's owner.
/// @dev    Deployed as an ERC-1167 minimal proxy by ERC6551Registry. The proxy
///         appends 128 bytes of immutable args (salt, chainId, tokenContract,
///         tokenId) to its runtime code; this implementation reads
///         (chainId, tokenContract, tokenId) via EXTCODECOPY at offset 0x4d.
///
/// Security model:
///   - owner()                    : dynamically = IERC721(tokenContract).ownerOf(tokenId).
///                                  Transfer the NFT -> control of this account transfers, atomically.
///   - execute()                  : restricted to current owner; CALL only, no DELEGATECALL
///                                  (delegatecall would let an attacker swap account semantics).
///   - state                      : monotonically increasing nonce; lets ERC-1271 verifiers
///                                  detect replay across changing owner / changing logic.
///   - isValidSignature           : checks signatures against current owner, supporting both
///                                  EOAs (ECDSA) and contract owners (ERC-1271).
contract ERC6551Account is
    IERC165,
    IERC1271,
    IERC6551Account,
    IERC6551Executable,
    IERC721Receiver,
    IERC1155Receiver
{
    uint256 private _state;

    receive() external payable {}

    /// @inheritdoc IERC6551Executable
    function execute(
        address to,
        uint256 value,
        bytes calldata data,
        uint8 operation
    ) external payable returns (bytes memory result) {
        require(_isValidSigner(msg.sender), "Invalid signer");
        require(operation == 0, "Only CALL supported");

        unchecked {
            ++_state;
        }

        bool success;
        (success, result) = to.call{value: value}(data);
        if (!success) {
            assembly {
                revert(add(result, 0x20), mload(result))
            }
        }
    }

    /// @inheritdoc IERC6551Account
    function isValidSigner(address signer, bytes calldata)
        external
        view
        returns (bytes4)
    {
        if (_isValidSigner(signer)) {
            return IERC6551Account.isValidSigner.selector;
        }
        return bytes4(0);
    }

    /// @inheritdoc IERC1271
    function isValidSignature(bytes32 hash, bytes memory signature)
        external
        view
        returns (bytes4 magicValue)
    {
        bool ok = SignatureChecker.isValidSignatureNow(owner(), hash, signature);
        if (ok) return IERC1271.isValidSignature.selector;
        return bytes4(0);
    }

    /// @notice Current controller of this account = current owner of the bound NFT.
    function owner() public view returns (address) {
        (uint256 chainId, address tokenContract, uint256 tokenId) = token();
        if (chainId != block.chainid) return address(0);
        return IERC721(tokenContract).ownerOf(tokenId);
    }

    /// @inheritdoc IERC6551Account
    function token()
        public
        view
        returns (uint256 chainId, address tokenContract, uint256 tokenId)
    {
        // Read the 96 bytes of immutable args that follow the 45-byte ERC-1167
        // proxy runtime: layout = [chainId(32) | tokenContract(32 padded) | tokenId(32)].
        bytes memory footer = new bytes(0x60);
        assembly {
            extcodecopy(address(), add(footer, 0x20), 0x4d, 0x60)
        }
        (chainId, tokenContract, tokenId) = abi.decode(
            footer,
            (uint256, address, uint256)
        );
    }

    /// @inheritdoc IERC6551Account
    function state() external view returns (uint256) {
        return _state;
    }

    function _isValidSigner(address signer) internal view returns (bool) {
        return signer != address(0) && signer == owner();
    }

    // -------------- ERC165 --------------
    function supportsInterface(bytes4 interfaceId)
        external
        pure
        returns (bool)
    {
        return
            interfaceId == type(IERC165).interfaceId ||
            interfaceId == type(IERC1271).interfaceId ||
            interfaceId == type(IERC721Receiver).interfaceId ||
            interfaceId == type(IERC1155Receiver).interfaceId ||
            interfaceId == 0x6faff5f1 || // IERC6551Account
            interfaceId == 0x51945447;   // IERC6551Executable
    }

    // -------------- Token receiver hooks --------------
    function onERC721Received(address, address, uint256, bytes calldata)
        external
        pure
        returns (bytes4)
    {
        return IERC721Receiver.onERC721Received.selector;
    }

    function onERC1155Received(
        address,
        address,
        uint256,
        uint256,
        bytes calldata
    ) external pure returns (bytes4) {
        return IERC1155Receiver.onERC1155Received.selector;
    }

    function onERC1155BatchReceived(
        address,
        address,
        uint256[] calldata,
        uint256[] calldata,
        bytes calldata
    ) external pure returns (bytes4) {
        return IERC1155Receiver.onERC1155BatchReceived.selector;
    }
}
