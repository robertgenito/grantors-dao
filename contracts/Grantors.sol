// SPDX-License-Identifier: GPL-3.0-only
// Genius is NOT LICENSED FOR COPYING.
// Genius (C) 2026. All Rights Reserved.
pragma solidity 0.8.26;

/*******************************************************************************
 *
 * Genius Grantors
 *
 * This is the Genius Grantors DAO that will be launched with the next launch of
 * the Genius Exchange.
 *
 ******************************************************************************/

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "./interfaces/genius/v2/IGeniusGrantorRegistry.sol";
// import "../Core.sol";

/*******************************************************************************
 *
 * PRIVATE ERRORS SPECIFIC TO THIS CONTRACT
 *
 ******************************************************************************/

error EBadArrayLength();
error EBadSeat();
error EBadValue();
error EExists();
error EExpired();
error ENullAddress();
error ENotEnoughVotes();
error ENotExecutableYet();
error ENotProposed();
error ENotSelf();
error EUnauthorizedDev();
error EBadProposalType();
error ENativeTargetNotAllowed();
error EGrantorTargetOnlySelf();
error EEmergencyAlreadyUsed();
error EGrantorNotUpdated();
error ESeatNotActive();

/*******************************************************************************
 *
 * PRIVATE INTERFACES SPECIFIC TO THIS CONTRACT
 *
 ******************************************************************************/

interface IConstitutionSeats {
    function seatIndex(address account) external view returns (uint8 indexPlusOne);
}

uint8 constant GRANTOR_SEAT_COUNT = 16;
uint40 constant GRANTOR_PROPOSAL_LIFETIME = 29 days;
uint8 constant GRANTOR_MAX_ACTIONS = 8;
uint16 constant GRANTOR_EXECUTE_THRESHOLD = 10;
uint8 constant GRANTOR_EMERGENCY_OVERRIDE_THRESHOLD = 5;
uint8 constant PROPOSAL_TYPE_NATIVE = 1;
uint8 constant PROPOSAL_TYPE_GRANTOR = 2;

/*******************************************************************************
 *
 * PRIVATE CONSTANTS SPECIFIC TO THIS CONTRACT
 *
 ******************************************************************************/

// proposed code:
//enum Operation { Call, DelegateCall }

// struct ProposalAction {
//     address target;        // 20 bytes
//     uint96  value;         // enough for ETH amounts; packs well
// //    uint32  gasLimit;      // optional: cap gas forwarded (0 = no cap)
// //    Operation op;          // 1 byte (but pads unless packed manually)
//     uint40 eta;
//     uint40 expiration;
//     bool executed;
//     bytes   data;          // calldata to send to target
// }

// (bool ok, bytes memory ret) = target.call{value: value}(data);

// struct QueuedTx {
//     bytes32 actionHash;    // keccak256 of (target,value,op,data, salt)
//     uint40  eta;           // earliest execution time (unix seconds) fits for ~34k years
//     uint40  expiresAt;     // optional expiry
//     uint32  nonce;         // replay protection / uniqueness
//     address proposer;      // who proposed (optional)
//     bool    executed;
//     bool    canceled;
// }

// bytes32 actionHash = keccak256(abi.encode(
//     target,
//     value,
//     gasLimit,
//     op,
//     keccak256(data),
//     salt,
//     chainId
// ));

// mapping(bytes32 => QueuedTx) public queue;     // actionHash => state
// mapping(bytes32 => Action) internal actions; // or store bytes separately

/*******************************************************************************
 *
 *
 * CONTRACT IMPLEMENTATION
 *
 *
 ******************************************************************************/

contract Grantors is ReentrancyGuard {
    using SafeERC20 for IERC20;

    /***************************************************************************
     *
     * Contract Construction: will always go at the top of the contract!
     *
     **************************************************************************/

    constructor(address constitution, address devOverride) {
        if (constitution == address(0) || devOverride == address(0)) {
            revert ENullAddress();
        }
        _constitution = IConstitutionSeats(constitution);
        _devOverride = devOverride;

        // feePlusOne defaults to 1 -> fee=0
        _feePlusOne = 1;
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
     * GENIUS CONTRACTS
     *
     *
     **************************************************************************/

    IConstitutionSeats internal immutable _constitution;
    address internal immutable _devOverride;

    /***************************************************************************
     *
     *
     * EVENT LOGGING
     *
     *
     **************************************************************************/

    event ProposalCreated(
        uint256 indexed proposalId,
        address indexed proposer,
        uint40 eta,
        uint40 txExpiresOn,
        uint40 expiresOn,
        uint8 actionCount,
        bytes32 url
    );

    event ProposalYesVote(uint256 indexed proposalId, address indexed voter, uint16 approvals);
    event ProposalExecuted(uint256 indexed proposalId);
    event ProposalDisagree(uint256 indexed proposalId, address indexed voter, bytes32 reason);
    event ProposalActionExecuted(
        uint256 indexed proposalId,
        uint8 indexed actionIndex,
        address indexed target,
        bytes4 selector,
        uint96 value
    );

    event ProposalFeeChanged(uint96 fee);
    event EmergencyDisbursed(address indexed token, address indexed to, uint256 amount);
    event EmergencySignaled(address indexed seat, address indexed newGrantor, uint8 count);
    event DevOverrideRequested(address indexed requester, address indexed newGrantor, uint8 count);
    event EmergencyUpgradeExecuted(
        address indexed requester,
        address indexed geniusRegistry,
        address indexed newGrantor,
        uint8 count
    );
    event SeatRegistered(address indexed seat);

    /***************************************************************************
     *
     *
     * STORAGE DATA STRUCTURES
     *
     *
     **************************************************************************/

    struct ProposalCore {
        // Slot 1
        address proposer;     // 20
        uint40 createdOn;     // 5
        uint40 eta;           // 5
        uint40 txExpiresOn;   // 5
        uint8 actionCount;    // 1
        uint8 executed;       // 1 (1=false,2=true)
        uint8 proposalType;   // 1 (1=native,2=grantor)

        // Slot 2
        uint40 expiresOn;     // 5
        uint16 approvals;     // 2
        uint16 yesBitmap;     // 2 (seat bits 0..15)
        bytes32 url;          // 32 (occupies its own slot; kept separate for UI)
    }

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

    function fee() public view returns (uint96 fee_) {
        unchecked {
            fee_ = uint96(_feePlusOne - 1);
        }
    }

    /***************************************************************************
     *
     *
     * INTERNAL ACCESS STATE DATA
     *
     *
     **************************************************************************/

    // proposalId starts at 1; 0 is prohibited
    uint256 internal _proposalCount;

    // proposalId => core (url stored in separate slot for UI friendliness)
    mapping(uint256 => ProposalCore) internal _proposals;

    // proposalId => actionIndex => actionHash
    mapping(uint256 => mapping(uint8 => bytes32)) internal _actionHash;

    // fee is stored as fee+1 so it can never become 0
    uint96 internal _feePlusOne;

    // newGrantor => packed [bitmap:16 | count:8]
    mapping(address => uint256) internal _emergency;

    // target => 0(non-existent), 1(false), 2(true)
    mapping(address => uint8) internal _nativeTargetAllowed;

    // emergency key => 0(non-existent), 1(false), 2(true)
    mapping(bytes32 => uint8) internal _emergencyUpgradeUsed;

    // seat => 0(non-existent), 1(false), 2(true)
    mapping(address => uint8) internal _seatActive;

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
        if (_seatIndexPlusOne(msg.sender) == 0) {
            revert EBadSeat();
        }
        _;
    }

    modifier onlySelf() {
        if (msg.sender != address(this)) {
            revert ENotSelf();
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

    function proposal(uint256 proposalId)
        external
        view
        returns (ProposalCore memory p)
    {
        p = _proposals[proposalId];
    }

    function actionHash(uint256 proposalId, uint8 index)
        external
        view
        returns (bytes32 h)
    {
        h = _actionHash[proposalId][index];
    }

    function emergencyCount(address newGrantor) 
        external 
        view 
        returns (uint8 c) 
    {
        uint256 packed = _emergency[newGrantor];
        c = uint8(packed >> 16);
    }

    function isNativeTargetAllowed(address target) 
        external 
        view 
        returns (bool allowed) 
    {
        allowed = (_nativeTargetAllowed[target] == 2);
    }

    function isSeatActive(address seat) external view returns (bool active) {
        active = (_seatActive[seat] == 2);
    }

    function proposalTypeNative() external pure returns (uint8 t) {
        t = PROPOSAL_TYPE_NATIVE;
    }

    function proposalTypeGrantor() external pure returns (uint8 t) {
        t = PROPOSAL_TYPE_GRANTOR;
    }

    /***************************************************************************
     *
     *
     * EXTERNAL FUNCTIONALITY for the user's interface
     *
     *
     **************************************************************************/

    /**
     * @notice Create a proposal. Anyone can propose.
     * @dev v0.1 stores only action hashes (not raw calldata) for gas/storage.
     *      Action hash format: keccak256(abi.encode(target, value, keccak256(data))).
     */
    function propose(
        bytes32[] calldata actionHashes,
        uint40 eta,
        uint40 txExpiresOn,
        bytes32 url,
        uint8 proposalType
    ) external payable returns (uint256 proposalId) {
        uint256 len = actionHashes.length;
        if (len == 0 || len > GRANTOR_MAX_ACTIONS) revert EBadArrayLength();
        if (proposalType != PROPOSAL_TYPE_NATIVE && proposalType != PROPOSAL_TYPE_GRANTOR) {
            revert EBadProposalType();
        }

        if (msg.value < fee()) revert EBadValue();

        unchecked {
            proposalId = ++_proposalCount;
        }

        uint40 now40 = uint40(block.timestamp);
        uint40 expiresOn = now40 + GRANTOR_PROPOSAL_LIFETIME;
        if (eta != 0 && eta > expiresOn) revert EBadValue();
        if (txExpiresOn != 0 && txExpiresOn < eta) revert EBadValue();

        ProposalCore storage p = _proposals[proposalId];
        p.proposer = msg.sender;
        p.createdOn = now40;
        p.eta = eta;
        p.txExpiresOn = txExpiresOn;
        p.actionCount = uint8(len);
        p.executed = 1;
        p.proposalType = proposalType;
        p.expiresOn = expiresOn;
        p.approvals = 0;
        p.yesBitmap = 0;
        p.url = url;

        _storeActionHashes(proposalId, actionHashes, len);

        emit ProposalCreated(
            proposalId,
            msg.sender,
            eta,
            txExpiresOn,
            expiresOn,
            uint8(len),
            url
        );
    }

    function voteYes(
        uint256 proposalId
    ) external onlySeat returns (uint16 approvals) {
        if (_seatActive[msg.sender] != 2) revert ESeatNotActive();

        ProposalCore storage p = _proposals[proposalId];
        if (p.executed == 0) revert ENotProposed();
        if (p.executed == 2) revert EExists();
        if (uint40(block.timestamp) > p.expiresOn) revert EExpired();

        uint8 seat = _seatIndexPlusOne(msg.sender);
        unchecked {
            seat -= 1;
        }
        uint16 bit = uint16(1 << seat);
        uint16 bm = p.yesBitmap;
        if ((bm & bit) != 0) revert EExists();

        bm |= bit;
        p.yesBitmap = bm;

        approvals = p.approvals + 1;
        p.approvals = approvals;

        emit ProposalYesVote(proposalId, msg.sender, approvals);
    }

    function registerSeat() external onlySeat {
        if (_seatActive[msg.sender] == 2) revert EExists();
        _seatActive[msg.sender] = 2;
        emit SeatRegistered(msg.sender);
    }

    function disagree(
        uint256 proposalId,
        bytes32 reason
    ) external onlySeat {
        ProposalCore storage p = _proposals[proposalId];
        if (p.executed == 0) revert ENotProposed();

        // No state change is allowed for "disagree".
        emit ProposalDisagree(proposalId, msg.sender, reason);
    }

    function execute(
        uint256 proposalId,
        address[] calldata targets,
        uint96[] calldata values,
        bytes[] calldata datas
    ) external nonReentrant returns (bytes[] memory rets) {
        ProposalCore storage p = _proposals[proposalId];
        if (p.executed == 0) revert ENotProposed();
        if (p.executed == 2) revert EExists();
        if (p.approvals < GRANTOR_EXECUTE_THRESHOLD) revert ENotEnoughVotes();

        uint40 now40 = uint40(block.timestamp);
        if (now40 > p.expiresOn) revert EExpired();
        if (p.eta != 0 && now40 < p.eta) revert ENotExecutableYet();
        if (p.txExpiresOn != 0 && now40 > p.txExpiresOn) revert EExpired();

        uint256 len = targets.length;
        if (len != p.actionCount) revert EBadArrayLength();
        if (len != values.length || len != datas.length) revert EBadArrayLength();

        p.executed = 2;

        rets = new bytes[](len);
        uint256 i;
        uint8 proposalType = p.proposalType;
        do {
            bytes32 expected = _actionHash[proposalId][uint8(i)];
            rets[i] = _executeAction(
                proposalId,
                uint8(i),
                targets[i],
                values[i],
                datas[i],
                expected,
                proposalType
            );

            unchecked { ++i; }
        } while (i != len);

        emit ProposalExecuted(proposalId);
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

    function _seatIndexPlusOne(address account) internal view returns (uint8 i) {
        i = _constitution.seatIndex(account);
        if (i > GRANTOR_SEAT_COUNT) {
            // Defensive: treat invalid registry results as non-seat.
            i = 0;
        }
    }

    function hashAction(address target, uint96 value, bytes calldata data)
        external
        pure
        returns (bytes32 h)
    {
        h = _hashAction(target, value, data);
    }

    function _hashAction(address target, uint96 value, bytes calldata data)
        internal
        pure
        returns (bytes32 h)
    {
        h = keccak256(abi.encode(target, value, keccak256(data)));
    }

    function _storeActionHashes(
        uint256 proposalId,
        bytes32[] calldata actionHashes,
        uint256 len
    ) internal {
        uint256 i;
        do {
            _actionHash[proposalId][uint8(i)] = actionHashes[i];
            unchecked { ++i; }
        } while (i != len);
    }

    function _selector(bytes calldata data) internal pure returns (bytes4 s) {
        if (data.length < 4) return bytes4(0);
        assembly {
            s := shr(224, calldataload(data.offset))
        }
    }

    function _executeAction(
        uint256 proposalId,
        uint8 actionIndex,
        address target,
        uint96 value,
        bytes calldata data,
        bytes32 expected,
        uint8 proposalType
    ) internal returns (bytes memory ret) {
        if (expected != _hashAction(target, value, data)) revert EBadValue();

        if (proposalType == PROPOSAL_TYPE_NATIVE) {
            if (_nativeTargetAllowed[target] != 2) revert ENativeTargetNotAllowed();
        } 
        else {
            // Grantor proposals execute only DAO-owned actions.
            if (target != address(this)) revert EGrantorTargetOnlySelf();
        }

        (bool ok, bytes memory callRet) = target.call{value: uint256(value)}(data);
        if (!ok) {
            assembly {
                revert(add(callRet, 0x20), mload(callRet))
            }
        }

        emit ProposalActionExecuted(
            proposalId, 
            actionIndex, 
            target, 
            _selector(data), 
            value
        );
        ret = callRet;
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

    function daoSetProposalFee(uint96 newFee) external onlySelf {
        // Store as fee+1 so it can never become 0.
        _feePlusOne = newFee + 1;
        emit ProposalFeeChanged(newFee);
    }

    function daoSetNativeTargetAllowed(
        address target, 
        bool allowed
    ) external onlySelf {
        if (target == address(0)) revert ENullAddress();
        _nativeTargetAllowed[target] = allowed ? 2 : 1;
    }

// I think we need this functionality for GENI. The proposal fees would be in GENI right?
// Also do we need functionality to move GENI in or out of different supplies?
// Or should it be handdled via Native Proposals. 

    function daoSweepERC20(address token, address to, uint256 amount) 
        external onlySelf nonReentrant 
    {
        if (token == address(0) || to == address(0)) revert ENullAddress();
        IERC20(token).safeTransfer(to, amount);
        emit EmergencyDisbursed(token, to, amount);
    }

    function daoSweepETH(address to, uint256 amount) 
        external onlySelf nonReentrant 
    {
        if (to == address(0)) revert ENullAddress();
        (bool ok, ) = to.call{value: amount}("");
        if (!ok) revert EBadValue();
        emit EmergencyDisbursed(address(0), to, amount);
    }

    /***************************************************************************
     *
     * EMERGENCY UPGRADE SIGNALING (no vote decrement)
     *
     **************************************************************************/

    function signalEmergencyUpgrade(address newGrantor, bool emitLog)
        external
        onlySeat
        returns (uint8 count)
    {
        if (newGrantor == address(0)) revert ENullAddress();

        uint8 seat = _seatIndexPlusOne(msg.sender);
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
        // TODO: should we have? else { revert(); }
    }

    function devOverrideRequest(address newGrantor, bool emitLog) external {
        if (msg.sender != _devOverride) revert EUnauthorizedDev();
        if (newGrantor == address(0)) revert ENullAddress();

        uint8 count = uint8(_emergency[newGrantor] >> 16);
        if (emitLog) {
            emit DevOverrideRequested(msg.sender, newGrantor, count);
        }
    }

    /**
     * @notice Manual emergency override for DAO upgrade/migration actions.
     * @dev Requires dev override account and at least 5 seat signals
     *      for the provided newGrantor. Execution target/data are flexible
     *      to support various grantor-registry upgrade paths.
     */
    function devOverrideUpgrade(
        address geniusRegistry, 
        address newGrantor, 
        bool emitLog
    )
        external
        nonReentrant
    {
        if (msg.sender != _devOverride) revert EUnauthorizedDev();
        if (geniusRegistry == address(0) || newGrantor == address(0)) revert ENullAddress();

        uint8 count = uint8(_emergency[newGrantor] >> 16);
        if (count < GRANTOR_EMERGENCY_OVERRIDE_THRESHOLD) revert ENotEnoughVotes();

        bytes32 key = keccak256(abi.encode(geniusRegistry, newGrantor));
        if (_emergencyUpgradeUsed[key] == 2) revert EEmergencyAlreadyUsed();
        _emergencyUpgradeUsed[key] = 2;

        IGeniusGrantorRegistry(geniusRegistry).changeGrantor(newGrantor);
        if (IGeniusGrantorRegistry(geniusRegistry).grantor() != newGrantor) {
            revert EGrantorNotUpdated();
        }

        if (emitLog) {
            emit EmergencyUpgradeExecuted(msg.sender, geniusRegistry, newGrantor, count);
        }
    }

    /***************************************************************************
     *
     * Other proposed internal functions
     *
     **************************************************************************/
    receive() external payable {}

    fallback() external payable {}
}
