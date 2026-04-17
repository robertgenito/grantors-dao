// SPDX-License-Identifier: GPL-3.0-only
pragma solidity 0.8.26;

interface IGeniusV2 {
    function transferFrom(address from, address to, uint256 value) external returns (bool);
    function transfer(address to, uint256 value) external returns(bool);
}
