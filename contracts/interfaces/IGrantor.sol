// SPDX-License-Identifier: GPL-3.0-only
pragma solidity 0.8.26;

interface IGrantor {
    function acceptOwnership() external;
    function callGenius(address target, uint96 value, bytes calldata data)
        external
        payable
        returns (bytes memory ret);
    function seatIndex(address account) external view returns (uint8 indexPlusOne);
}
