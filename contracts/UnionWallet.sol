//SPDX-License-Identifier: GNU GPLv3
pragma solidity ^0.8.2;

import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";

// Union wallet is a way to use any registered wallet as a substitute
// to a "main" one, which we call identity.
// Kind-a 1:N multisig.
contract UnionWallet is Initializable {
    mapping(address => address) linkToIdentity;

    function resolveIdentity(address _address) public view returns (address) {
        // When no links, identity is the wallet itself.
        return (linkToIdentity[_address] != address(0x0))
                ? linkToIdentity[_address]
                : _address;
    }

    function attachToIdentity(address _address) public {
        // Allowing to attach anything to msg.sender's identity.
        _attachToIdentity(_address, msg.sender);
    }

    function _attachToIdentity(address _address, address _identityOrAnotherAddress) internal {
        require(linkToIdentity[_address] == address(0x0), "Can't overwrite link");
        require(_address != _identityOrAnotherAddress, "Can't attach to myself");
        require(_address != resolveIdentity(_identityOrAnotherAddress), "Can't attach parent to child");
        linkToIdentity[_address] = resolveIdentity(_identityOrAnotherAddress);
    }

    function detachFromIdentity(address _address) public {
        require(msg.sender != resolveIdentity(msg.sender), "Can't detach identity");
        require(resolveIdentity(msg.sender) == resolveIdentity(_address), "Address does not belong to this identity");
        linkToIdentity[_address] = address(0x0);
    }
}
