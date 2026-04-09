// SPDX-License-Identifier: GPL-3.0-only
// Genius is NOT LICENSED FOR COPYING.
// Genius (C) 2026. All Rights Reserved.
pragma solidity 0.8.26;

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

/*******************************************************************************
 *
 * PRIVATE INTERFACES SPECIFIC TO THIS CONTRACT
 *
 ******************************************************************************/

/*******************************************************************************
 *
 * PRIVATE CONSTANTS SPECIFIC TO THIS CONTRACT
 *
 ******************************************************************************/
uint8 constant GRANTOR_SEAT_COUNT = 16;
uint40 constant GRANTOR_PROPOSAL_LIFETIME = 29 days;
uint8 constant GRANTOR_MAX_ACTIONS = 8;
uint16 constant GRANTOR_EXECUTE_THRESHOLD = 10;
/*******************************************************************************
 *
 *
 * CONTRACT IMPLEMENTATION
 *
 *
 ******************************************************************************/

contract Constitution {
    /***************************************************************************
     *
     * Contract Construction: will always go at the top of the contract!
     *
     **************************************************************************/

    constructor(address[GRANTOR_SEAT_COUNT] memory seatsInit) {
        // Storage strategy: 0 = non-existent, 1 = false, 2 = true.
        // seatIndexPlusOne uses 0 as non-seat sentinel.
        uint256 i;
        do {
            address s = seatsInit[i];
            if (s == address(0)) revert ENullAddress();
            if (_seatIndexPlusOne[s] != 0) revert EExists();
            _seats[i] = s;
            unchecked {
                _seatIndexPlusOne[s] = uint8(i + 1);
                ++i;
            }
        } while (i != GRANTOR_SEAT_COUNT);
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

    function seats(uint256 index) external view returns (address seat) {
        seat = _seats[index];
    }

    function seatIndex(address account) 
        external 
        view 
        returns (uint8 indexPlusOne) 
    {
        indexPlusOne = _seatIndexPlusOne[account];
    }

    function emergencyCount(address newGrantor) 
        external 
        view 
        returns (uint8 c) 
    {
        uint256 packed = _emergency[newGrantor];
        c = uint8(packed >> 16);
    }

    /***************************************************************************
     *
     *
     * INTERNAL ACCESS STATE DATA
     *
     *
     **************************************************************************/

    address[GRANTOR_SEAT_COUNT] internal _seats;
    mapping(address => uint8) internal _seatIndexPlusOne;

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

    modifier onlySeat() {
        if (_seatIndexPlusOne[msg.sender] == 0) {
            revert EBadSeat();
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
    function signalEmergencyUpgrade(address newGrantor, bool emitLog)
        external
        onlySeat
        returns (uint8 count)
    {
        if (newGrantor == address(0)) revert ENullAddress();

        uint8 seat = _seatIndexPlusOne[msg.sender];
        unchecked { seat -= 1; }
        uint16 bit = uint16(1 << seat);

        uint256 packed = _emergency[newGrantor];
        uint16 bm = uint16(packed);
        if ((bm & bit) != 0) revert EExists();

        bm |= bit;
        count = uint8(packed >> 16) + 1;
        _emergency[newGrantor] = uint256(bm) | (uint256(count) << 16);

        if (emitLog) {
            emit EmergencySignaled(msg.sender, newGrantor, count);
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
