// SPDX-License-Identifier: GPL-3.0-only
pragma solidity 0.8.26;

interface IGeniusGrantorRegistry {
    function grantor() external view returns (address);
    function changeGrantor(address newGrantor) external;
}
