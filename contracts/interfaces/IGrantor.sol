// SPDX-License-Identifier: GPL-3.0-only
pragma solidity 0.8.26;

interface IGrantor {
    function acceptOwnership() external;
    function seatIndex(address account) external view returns (uint8 indexPlusOne);
}
