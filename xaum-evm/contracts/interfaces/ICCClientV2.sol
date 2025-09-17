// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.24;

interface ICCClientV2 {
    function ccReceive32(bytes calldata message) external;

    function msgOfCcSendToken32(
        address sender,
        bytes32 receiver,
        uint256 value
    ) external view returns (bytes memory message);

    function ccSendToken32(
        address sender,
        bytes32 receiver,
        uint256 value
    ) external returns (bytes memory message);

    function msgOfCcSendMintBudget(
        uint112 value
    ) external view returns (bytes memory message);

    function ccSendMintBudget32(
        uint112 value
    ) external returns (bytes memory message);
}
