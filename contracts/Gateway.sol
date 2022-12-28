//SPDX-License-Identifier: GNU GPLv3
pragma solidity ^0.8.2;

import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/cryptography/EIP712Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/cryptography/ECDSAUpgradeable.sol";

import "./RewardCalcs.sol";

// Gateway implements ERC712 protocol.
contract Gateway is EIP712Upgradeable, OwnableUpgradeable {
    RewardCalcs rewards;

    function initialize() public initializer {
        __EIP712_init("EVO Gateway", "1");
        __Ownable_init();
    }

    function setRewards(RewardCalcs _rewards) public onlyOwner {
        rewards = _rewards;
    }

    function setRef(address newUser, address referral, uint8 v, bytes32 r, bytes32 s) public {
        bytes32 hash = _hashTypedDataV4(keccak256(abi.encode(
            keccak256("setRef(address newUser,address referral)"),
            newUser,
            referral
        )));
        address signer = ECDSAUpgradeable.recover(hash, v, r, s);
        require(signer == newUser, "setRef: invalid signature");
        require(signer != address(0x0), "setRef: invalid signature 2");

        rewards.setReferral(newUser, referral);
    }
}
