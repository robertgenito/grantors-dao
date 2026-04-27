// SPDX-License-Identifier: GPL-3.0-only
// Genius is NOT LICENSED FOR COPYING.
// Genius (C) 2026. All Rights Reserved.
pragma solidity 0.8.26;
import "./AllContracts.sol";

// Constitution -> rename to Grantors.sol
//      * This file will be launched with the Genius contracts.
//      * Genius will have the address of Grantors.sol as a constant to prevent
//          gas bloat.
//      * "Grantors" will become the most fundamental actions.
//      * Grantor specific functions are mentioned in the technical white paper
//          https://geni.to/smartcontract
//      * THE CONTRACT ADDRESS OF THIS CONTRACT SHOULD BE PREDETERMINED,
//          so that Genius can know who it points to.
//      * THAT PREDETERMINED ADDRESS, is what Genius's constant is set to:
//          AllContracts.sol#GENIUS_CONTRACT_GRANTORS;
//      * Genius's ecosystem will already know who this DAO is.
//      * IMPORTANT: whatever account launches this, IS THE FIRST OWNER.

/*******************************************************************************
 *
 * Genius Constitution
 *
// This is the Genius Constitution.  It is basically the immutable laws of
// Genius that go over:
// ---> What smart contract is the acting Grantor?
// ---> The separate "Treasury" is no-longer separate; the Grantor *is* the
//      Treasury.
//
// This contract may hold some "persistent data" that Genius's economy always
// relies on.  We'll see about that!  Anything grantor-ish functionally here
// will always remain here, and will be pulled out of any non-governance smart
// contracts.
 *
 ******************************************************************************/

/*******************************************************************************
 *
 * PRIVATE ERRORS SPECIFIC TO THIS CONTRACT
 *
 ******************************************************************************/

error EBadSeat();
error EExists();
error ENullAddress();
error EUnauthorized();
error ENotPendingOwner();
error ECallFailed();
error ENotOwner();
error EBadCalldata();
error EBadSelector();

/*******************************************************************************
 *
 * PRIVATE INTERFACES SPECIFIC TO THIS CONTRACT
 *
 ******************************************************************************/
interface IGeniusToken {
    function changeTreasury(address _treasury) external;
    function changeGrantor(address _newGrantor) external;
}

interface IVault {
    function beginCreditIssuance(address token, uint256 initRate) external;
    function pauseCreditIssuance(address token) external;
    function resumeCreditIssuance(address token) external;
    function purgeVault(address beneficiary, uint256 index) external;
}

interface INftController {
    function newEdition(address _newEdition, uint256 reserved) external;
    function expelEdition(address _edition) external;
    function setReserved(address _edition, uint256 _reserved) external;
}

interface INftRoyaltyReceiver {
    function setBurnCosts(uint128 _weeklyAmount, uint128 _monthlyAmount) external;
}

/*******************************************************************************
 *
 * PRIVATE CONSTANTS SPECIFIC TO THIS CONTRACT
 *
 ******************************************************************************/
uint8 constant GRANTOR_SEAT_COUNT = 16;
uint40 constant GRANTOR_PROPOSAL_LIFETIME = 29 days;
uint8 constant GRANTOR_MAX_ACTIONS = 8;
uint16 constant GRANTOR_EXECUTE_THRESHOLD = 10;
// ^-- All of these can be in a LIB

/*******************************************************************************
 *
 *
 * CONTRACT IMPLEMENTATION
 *
 *
 ******************************************************************************/

contract Constitution is AllContracts {
    /***************************************************************************
     *
     * Contract Construction: will always go at the top of the contract!
     *
     **************************************************************************/
    constructor() {
        // emit a log that shows who the first owner is
        // There should be a struct that gets passed to the constructor that
        // shows who the grantor is and how much $$ amount of liquidity they get access to
        // And when they can access that liquidity

        // eg
//         struct {
// address account;
// uint88 liquidityAllowanceUsd;
// uint8 firstLiquidityDay;
// }
        owner = msg.sender;

    }

    /***************************************************************************
     *
     *
     * [ERC/EIP Name] Abstract
     * TODO: remove this comment after you have read this note!  The purpose of
     * this section is to implement anything SPECIFIC (or overriding) in regard
     * to the abstract that the contract implements.
     *
     *
     **************************************************************************/

    /***************************************************************************
     *
     *
     * EVENT LOGGING
     *
     *
     **************************************************************************/

    event EmergencySignaled(
        address indexed seat, 
        address indexed newGrantor, 
        uint8 count
    );
    event OwnershipTransferStarted(address indexed previousOwner, address indexed pendingOwner);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);
    event GeniusCallExecuted(address indexed target, uint96 value, bytes4 selector);

    /***************************************************************************
     *
     *
     * STORAGE DATA STRUCTURES
     *
     *
     **************************************************************************/

    /***************************************************************************
     *
     *
     * MEMORY DATA STRUCTURES
     *
     *
     **************************************************************************/

    /***************************************************************************
     *
     *
     * PUBLIC ACCESS STATE DATA
     *
     *
     **************************************************************************/


    // Genius -> const GRANTOR_CONTRACT_ADDRESS ->
    // protected functions that only the Grantor(s) can run...
    // if (msg.sender != GRANTOR_CONTRACT_ADDRESS)) { ...
    address public owner;
    address private pendingOwner;

    function getPendingOwner() external view returns (address pendingOwner_) {
        pendingOwner_ = pendingOwner;
    }

    // When the Owner (the DAO Contract) -- GeniusDao?

    function emergencyCount(address newDaoContract) 
        external 
        view 
        returns (uint8 c) 
    {
        uint256 packed = _emergency[newDaoContract];
        c = uint8(packed >> 16);
    }

    /***************************************************************************
     *
     *
     * INTERNAL ACCESS STATE DATA
     *
     *
     **************************************************************************/

// Frankly, I'd just call this a "grantor" -- a "seat" implies that someone else can sit in it.
// This first version will be super simple.  It's important to get terminology as accurate as possible!
// OR, maybe these "seats" are whitelistSeats?  (accounts that can always have a seat, i.e. they're
// whitelisted..)
    // address[GRANTOR_SEAT_COUNT] internal _whitelistSeats;
    // mapping(address => uint8) internal _whitelistSeatIndexPlusOne;

    // newGrantor => packed [bitmap:16 | count:8]
    mapping(address => uint256) internal _emergency;

    /***************************************************************************
     *
     *
     * PRIVATE STATE DATA -- Abstract Contracts ONLY!!!
     *
     * For abstract contracts, the private members will be within their very own
     * section.  If this contract is not abstract, do not implement private
     * members, and remove this comment block!
     *
     *
     **************************************************************************/

    /***************************************************************************
     *
     *
     * FUNCTION MODIFIERS
     *
     *
     **************************************************************************/

    modifier onlyOwner() {
        if (msg.sender != owner) {
            revert ENotOwner();
        }
        _;
    }

    /***************************************************************************
     *
     *
     * GRANTOR(S) PRIVILEGE FUNCTIONALITY ACCESS - GATED BY ACCOUNT
     *
     *
     **************************************************************************/

    /***************************************************************************
     *
     *
     * ECOSYSTEM CONTRACT PRIVILEGE FUNCTIONALITY
     *
     *
     **************************************************************************/
    // Two-way owner transfer:
    // 1) current owner nominates a new owner (contract or account),
    // 2) nominated owner calls acceptOwnership.
    function electNewGrantor(address newOwner) external onlyOwner {
        // Lets have these logs match the function name
        if (newOwner == address(0)) revert ENullAddress();
        pendingOwner = newOwner;
        emit OwnershipTransferStarted(owner, newOwner);
    }

    function acceptOwnership() external {
        address nominated = pendingOwner;
        if (msg.sender != nominated) revert ENotPendingOwner();
        address previousOwner = owner;
        owner = nominated;
        pendingOwner = address(0);
        emit OwnershipTransferred(previousOwner, nominated); //lET'S CALL IT NEW OWNER
    }

    // The Grantor contract is the single "house" that executes calls into Genius contracts.
    // Owner is expected to be GeniusDao once ownership is accepted.
    function callAnyContract(address target, uint96 value, bytes calldata data)
        external
        payable
        onlyOwner
        returns (bytes memory ret)
    {
        if (target == address(0)) revert ENullAddress();

        (bool ok, bytes memory callRet) = target.call{value: uint256(value)}(data);
        if (!ok) {
            revert ECallFailed();
        }

        emit GeniusCallExecuted(target, value, bytes4(data));
        ret = callRet;
    }

    function callGeniusToken(bytes calldata data)
        external
        onlyOwner
        returns (bytes memory ret)
    {
        bytes4 selector = _selector(data);
        if (
            selector != IGeniusToken.changeTreasury.selector &&
            selector != IGeniusToken.changeGrantor.selector
        ) {
            revert EBadSelector();
        }
        ret = _callTarget(GENIUS_CONTRACT_TOKEN, data, 0, selector);
    }

    function callVault(bytes calldata data)
        external
        onlyOwner
        returns (bytes memory ret)
    {
        bytes4 selector = _selector(data);
        if (
            selector != IVault.beginCreditIssuance.selector &&
            selector != IVault.pauseCreditIssuance.selector &&
            selector != IVault.resumeCreditIssuance.selector &&
            selector != IVault.purgeVault.selector
        ) {
            revert EBadSelector();
        }
        ret = _callTarget(GENIUS_CONTRACT_VAULT, data, 0, selector);
    }

    function callNftController(bytes calldata data)
        external
        onlyOwner
        returns (bytes memory ret)
    {
        bytes4 selector = _selector(data);
        if (
            selector != INftController.newEdition.selector &&
            selector != INftController.expelEdition.selector &&
            selector != INftController.setReserved.selector
        ) {
            revert EBadSelector();
        }
        ret = _callTarget(GENIUS_CONTRACT_NFT_CONTROLLER, data, 0, selector);
    }

    function callNftRoyalties(bytes calldata data)
        external
        onlyOwner
        returns (bytes memory ret)
    {
        bytes4 selector = _selector(data);
        if (selector != INftRoyaltyReceiver.setBurnCosts.selector) {
            revert EBadSelector();
        }
        ret = _callTarget(GENIUS_CONTRACT_NFT_ROYALTIES, data, 0, selector);
    }

    /***************************************************************************
     *
     *
     * EXTERNAL VIEWS only for the UI (not internal, not public)
     *
     *
     **************************************************************************/

    /***************************************************************************
     *
     *
     * EXTERNAL FUNCTIONALITY for the user's interface
     *
     *
     **************************************************************************/

    /**
     * @notice Emergency signal for a future Grantor/DAO upgrade.
     * @dev YES-only cumulative signaling: cannot decrease.
     */
    function signalEmergencyUpgrade(address newDaoContract, bool emitLog)
        external
        onlyOwner
        returns (uint8 count)
    {
// let's get terminology down: have the "grantor" be the person (the account)
// and "DAO Contract" to refer to the mechanics of the governance.
// I'm implying that a better name for "newGrantor" is "newDaoContract".
        if (newDaoContract == address(0)) revert ENullAddress();

        uint256 packed = _emergency[newDaoContract];
        if (packed != 0) revert EExists();
        count = 1;
        _emergency[newDaoContract] = uint256(count) << 16;

        if (emitLog) {
            emit EmergencySignaled(msg.sender, newDaoContract, count);
        }
    }

    /***************************************************************************
     *
     *
     * PUBLIC ACCESS FUNCTIONALITY for the user and this contract
     *
     *
     **************************************************************************/

    /***************************************************************************
     *
     *
     * INTERNAL FUNCTIONALITY
     *
     *
     **************************************************************************/
    function _callTarget(
        address target,
        bytes calldata data,
        uint96 value,
        bytes4 selector
    ) internal returns (bytes memory ret) {
        (bool ok, bytes memory callRet) = target.call{value: uint256(value)}(data);
        if (!ok) revert ECallFailed();
        emit GeniusCallExecuted(target, value, selector);
        ret = callRet;
    }

    function _selector(bytes calldata data) internal pure returns (bytes4 s) {
        if (data.length < 4) revert EBadCalldata();
        assembly {
            s := shr(224, calldataload(data.offset))
        }
    }

    /***************************************************************************
     *
     *
     * PRIVATE FUNCTIONALITY -- Abstract Contracts ONLY!!!
     *
     * For abstract contracts, the private functionality will be within their
     * very own section.  If this contract is not abstract, do not implement
     * private functions, and remove this comment block!
     *
     *
     **************************************************************************/
}
