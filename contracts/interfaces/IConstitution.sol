// SPDX-License-Identifier: GPL-3.0-only
pragma solidity 0.8.26;

interface IConstitution {
    function acceptOwnership() external;
    function electNewGrantor(address newOwner) external;
    function callAnyContract(address target, uint96 value, bytes calldata data)
        external
        payable
        returns (bytes memory ret);
    function seatIndex(address account) external view returns (uint8 indexPlusOne);
}
