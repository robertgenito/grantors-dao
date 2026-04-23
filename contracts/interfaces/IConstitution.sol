// SPDX-License-Identifier: GPL-3.0-only
pragma solidity 0.8.26;

interface IConstitution {
    function acceptOwnership() external;
    function electNewGrantor(address newOwner) external;
    function callGeniusToken(bytes calldata data) external returns (bytes memory ret);
    function callVault(bytes calldata data) external returns (bytes memory ret);
    function callNftController(bytes calldata data) external returns (bytes memory ret);
    function callNftRoyalties(bytes calldata data) external returns (bytes memory ret);
    function callAnyContract(address target, uint96 value, bytes calldata data)
        external
        payable
        returns (bytes memory ret);
    function seatIndex(address account) external view returns (uint8 indexPlusOne);
}
