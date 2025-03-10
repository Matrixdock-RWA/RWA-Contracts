// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.24;

interface ICCIPClient {
    function ccReceive(bytes calldata message) external;

    function msgOfCcSendToken(
        address sender,
        address receiver,
        uint256 value
    ) external view returns (bytes memory message);

    function ccSendToken(
        address sender,
        address receiver,
        uint256 value
    ) external returns (bytes memory message);

    function msgOfCcSendMintBudget(
        uint112 value
    ) external view returns (bytes memory message);

    function ccSendMintBudget(
        uint112 value
    ) external returns (bytes memory message);
}
