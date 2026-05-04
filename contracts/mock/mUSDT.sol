// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

// Import standard OpenZeppelin ERC20 implementation
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

contract mUSDT is ERC20, Ownable {
    
    // Initialize token with name and symbol
    constructor() ERC20("Tether USD", "USDT") Ownable() {}

    // Mock USDT typically uses 6 decimals
    function decimals() public pure override returns (uint8) {
        return 6;
    }

    // Function to allow testing/minting of fake USDT
    function mint(address to, uint256 amount) public onlyOwner {
        _mint(to, amount);
    }
}
