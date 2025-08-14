// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.24;

import "./Delayable.sol";

contract CustomerManager is Delayable {

    event WhiteListUpdated(address[] addresses, bool status);

    mapping(address => bool) public whiteList;

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(
        uint64 _delay,
        address _owner,
        address _operator,
        address _revoker
    ) public initializer {
        __CustomerManager_init(
            _delay,
            _owner,
            _operator,
            _revoker
        );
    }

    function __CustomerManager_init(
        uint64 _delay,
        address _owner,
        address _operator,
        address _revoker
    ) internal onlyInitializing {
        __Delayable_init(_owner, _operator, _revoker);
        delay = _delay;
    }

    function setWhiteList(address[] memory _addresses, bool _status) public onlyOperator {
        for (uint256 i = 0; i < _addresses.length; i++) {
            whiteList[_addresses[i]] = _status;
        }
        emit WhiteListUpdated(_addresses, _status);
    }

    function inWhiteList(address _address) public view returns (bool) {
        return whiteList[_address];
    }
}

