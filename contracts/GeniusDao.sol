// SPDX-License-Identifier: GPL-3.0-only
// Genius is NOT LICENSED FOR COPYING.
// Genius (C) 2026. All Rights Reserved.
pragma solidity 0.8.26;

// Grantors.sol -> rename to GeniusDao.sol
//      * This file is launched solo ... it can be launched any time.  it can
//          be launched AFTER Genius.

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
import "./interfaces/IGrantor.sol";

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
error EBadProposalType();
error ENativeTargetNotAllowed();
error EGrantorTargetOnlySelf();
error ESeatNotActive();
error EUnsupportedFeeToken();
error EInsufficientProposalFee();
error EUnexpectedNativeValue();
error EReentrant();

/*******************************************************************************
 *
 * PRIVATE INTERFACES SPECIFIC TO THIS CONTRACT
 *
 ******************************************************************************/

interface IConstitutionSeats {
    function seatIndex(address account) external view returns (uint8 indexPlusOne);
}

interface IGrantorOwnership {
    function acceptOwnership() external;
}

// In most cases, I found it better to leave constants at their default size of `uint256`
// because then it's easier for the engineer to read visually.  When the size constraints
// actually become important, then you see it directly in the code when you're reading
// the code and implementing the code.
uint256 constant GRANTOR_SEAT_COUNT = 16;
uint256 constant GRANTOR_PROPOSAL_LIFETIME = 29 days;
uint256 constant GRANTOR_EXECUTION_GRACE = 5 days;
uint256 constant GRANTOR_MAX_ACTIONS = 8;
uint256 constant GRANTOR_EXECUTE_THRESHOLD = 10;
uint256 constant PROPOSAL_TYPE_NATIVE = 1;
uint256 constant PROPOSAL_TYPE_GRANTOR = 2;
uint8 constant PM_ACTION_COUNT_MASK = 0x0f;
uint8 constant PM_EXECUTED_MASK = 0x10;
uint8 constant PM_PROPOSAL_TYPE_SHIFT = 5;
// TODO: ^-- All of these can be in a LIB

/*******************************************************************************
 *
 * PRIVATE CONSTANTS SPECIFIC TO THIS CONTRACT
 *
 ******************************************************************************/

/*******************************************************************************
 *
 *
 * CONTRACT IMPLEMENTATION
 *
 *
 ******************************************************************************/

contract GeniusDao is ReentrancyGuard {
    using SafeERC20 for IERC20;

    /***************************************************************************
     *
     * Contract Construction: will always go at the top of the contract!
     *
     **************************************************************************/

    constructor(address constitution, address devOverride, address geniV2) {
        if (constitution == address(0) || devOverride == address(0) || geniV2 == address(0)) {
            revert ENullAddress();
        }
        _constitution = IConstitutionSeats(constitution);
        _geniV2 = geniV2;
        _globals.nativeExecLock = 1;

        // v0.1 defaultsfee structure:
        // - 5,000,000 GENI (v2)
        // - 0.02 ETH
        _proposalFeeByToken[geniV2] = 5_000_000e9;
        _proposalFeeByToken[address(0)] = 0.02 ether;
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

// Let's be clear that the constitution is actually the code that never changes.
// It's not that the seats are unchangeable; it's that the interface between the
// grantors of the world and genius's code is immutable.
    IConstitutionSeats internal immutable _constitution;

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
// Does a UI really need this information?  Doesn't the UI get the timestamps from
// the log itself?

// Isn't the Block log timestamp only “emitted at” time.  it does not encode both lifecycle constraints.

        uint40 txExpiresOn,
        uint40 expiresOn,
        uint8 actionCount,
        uint8 linkProtocol,
        bytes32 metadataHash
    );

    event ProposalYesVote(uint256 indexed proposalId, address indexed voter, uint16 approvals);
    event ProposalExecuted(uint256 indexed proposalId);
    event ProposalDisagree(uint256 indexed proposalId, address indexed voter, bytes32 reason);
    event ProposalActionExecuted(
        uint256 indexed proposalId,
        uint8 indexed actionIndex,
        address indexed target,
// what's the selector again? ;x

// Native proposal action: selector of the Genius contract function, 
// e.g. beginCreditIssuance(address,uint256) on Vault.
//Grantor proposal action: selector of a DAO self-call function, e.g. daoSweepERC20
        bytes4 selector,
        uint96 value
    );

    event ProposalFeeChanged(uint96 fee);
    event ProposalFeeTokenChanged(address indexed token, uint96 fee);
    event EmergencyDisbursed(address indexed token, address indexed to, uint256 amount);

// Let's call this "Accepted", like "GrantorWhitelistAccepted", implying that
// the grantor's wallet account has accepted their whitelist invitation.
    event GrantorWhitelistAccepted(address indexed seat);

    /***************************************************************************
     *
     *
     * STORAGE DATA STRUCTURES
     *
     *
     **************************************************************************/

    struct ProposalCore {
        address proposer;     // 20
        uint40 createdOn;     // 5
        uint40 eta;           // 5
// ^-- this is already slot 1, with 16 bits remaining.

// if we know when it's created, do we need to save when it expires?
        uint40 txExpiresOn;   // 5

// just pack these into a single uint8
        // packed: [7..5]=proposalType, [4]=executed, [3..0]=actionCount
        uint8 meta;           // 1

        // Slot 2
        uint16 approvals;     // 2

        // it’s meant to identify how to interpret proposal link data, e.g.:
        // 0 = unspecified
        // 1 = https
        // 2 = http
        // 3 = ipfs
        uint8 linkProtocol;   // e.g, IPFS, HTTPS, etc.
// I appreciate this approach, but let's keep it an actual tally count.
        // Keep tally as approvals, and track uniqueness in _votedBySeat mapping.


// Slot 3+: proposal metadata for UI display/discovery.
        bytes32 metadataHash;
    }

    /***************************************************************************
     *
     *
     * MEMORY DATA STRUCTURES
     *
     *
     **************************************************************************/

    //These don't consume storage only used for calldata
    struct ProposeInput {
        uint40 eta;
        uint40 txExpiresOn;
        uint8 linkProtocol;
        bytes32 metadataHash;
        address feeToken;
        uint256 proposalType;
    }

    // Global state packing
    struct GlobalState {
        // tracks proposal data. next proposalId, _proposalCount
        uint64 proposalCount;

        // block recursive re-entry during external/native action execution 
        // without paying mutex cost on other paths.
        uint8 nativeExecLock; // 1 = unlocked, 2 = locked
    }

    /***************************************************************************
     *
     *
     * PUBLIC ACCESS STATE DATA
     *
     *
     **************************************************************************/

// why not just make the variable public from the start?  my memory may be rusty
    function fee() public view returns (uint96 fee_) {
        fee_ = _proposalFeeByToken[address(0)];
    }

    function feeByToken(address token) public view returns (uint96 fee_) {
        fee_ = _proposalFeeByToken[token];
    }

    /***************************************************************************
     *
     *
     * INTERNAL ACCESS STATE DATA
     *
     *
     **************************************************************************/

    // Packed global scalar state.
    GlobalState internal _globals;
    address internal immutable _geniV2;

// Why not make it public?  that way, the UI can freely grab proposals without
// the cost of implementing access or functions.
    // proposalId => core (url stored in separate slot for UI friendliness)
    mapping(uint256 => ProposalCore) public _proposals;

    // proposalId => actionIndex => actionHash
    mapping(uint256 => mapping(uint256 => bytes32)) internal _actionHash;

    // proposal fee by token (address(0) = native token)
    mapping(address => uint96) internal _proposalFeeByToken;

    // target => 0(non-existent), 1(false), 2(true)
    mapping(address => uint8) internal _nativeTargetAllowed;

    // seat => 0(non-existent), 1(false), 2(true)
    mapping(address => uint8) internal _seatActive;

    // proposalId => seatIndexZeroBased => 0(non-existent),1(false),2(true)
    mapping(uint256 => mapping(uint8 => uint8)) internal _votedBySeat;

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

// For clarity and less ambiguity, let's rename this.
    modifier onlyGrantorSeat() {
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

    function actionHash(uint256 proposalId, uint256 index)
        external
        view
        returns (bytes32 h)
    {
        h = _actionHash[proposalId][index];
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

    function proposalTypeNative() external pure returns (uint256 t) {
        t = PROPOSAL_TYPE_NATIVE;
    }

    function proposalTypeGrantor() external pure returns (uint256 t) {
        t = PROPOSAL_TYPE_GRANTOR;
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
        if (len == 0) return;
        uint256 i;
        do {
            _actionHash[proposalId][i] = actionHashes[i];
            unchecked { ++i; }
        } while (i != len);
    }

    function _packMeta(uint256 actionCount_, uint256 proposalType_, bool executed_)
        internal
        pure
        returns (uint8 m)
    {
        m = uint8(actionCount_ & PM_ACTION_COUNT_MASK);
        m |= uint8(proposalType_ << PM_PROPOSAL_TYPE_SHIFT);
        if (executed_) m |= PM_EXECUTED_MASK;
    }

    function _actionCount(uint8 meta) internal pure returns (uint256 c) {
        c = uint256(meta & PM_ACTION_COUNT_MASK);
    }

    function _proposalType(uint8 meta) internal pure returns (uint256 t) {
        t = uint256(meta >> PM_PROPOSAL_TYPE_SHIFT);
    }

    function _executed(uint8 meta) internal pure returns (bool e) {
        e = ((meta & PM_EXECUTED_MASK) != 0);
    }

    function _selector(bytes calldata data) internal pure returns (bytes4 s) {
        if (data.length < 4) return bytes4(0);
        assembly {
            s := shr(224, calldataload(data.offset))
        }
    }

    function _executeAction(
        uint256 proposalId,
        uint256 actionIndex,
        address target,
        uint96 value,
        bytes calldata data,
        uint256 proposalType
    ) internal returns (bytes memory ret) {
        bytes32 expected = _actionHash[proposalId][actionIndex];
        if (expected != _hashAction(target, value, data)) revert EBadValue();

        if (proposalType == PROPOSAL_TYPE_NATIVE) {
            if (_nativeTargetAllowed[target] != 2) revert ENativeTargetNotAllowed();
        } 
        else {
// Anyone from the public should be allowed to execute anything that has reached
// the approval threshold.

// execute() is external and not seat-restricted.
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
            uint8(actionIndex), 
            target, 
            _selector(data), 
            value
        );
        ret = callRet;
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
        ProposeInput calldata input
    ) external payable returns (uint256 proposalId) {
        uint256 len = actionHashes.length;
        if (len > GRANTOR_MAX_ACTIONS) revert EBadArrayLength();
        if (input.proposalType != PROPOSAL_TYPE_NATIVE && input.proposalType != PROPOSAL_TYPE_GRANTOR) {
            revert EBadProposalType();
        }
        uint96 feeRequired = _proposalFeeByToken[input.feeToken];
        if (feeRequired == 0) revert EUnsupportedFeeToken();
        if (input.feeToken == address(0)) {
            if (msg.value < feeRequired) revert EInsufficientProposalFee();
        } 
        else {
            if (msg.value != 0) revert EUnexpectedNativeValue();
            IERC20(input.feeToken).safeTransferFrom(msg.sender, address(this), feeRequired);
        }

        unchecked {
            proposalId = uint256(++_globals.proposalCount);
        }

        uint40 now40 = uint40(block.timestamp);
        uint40 expiresOn = now40 + uint40(GRANTOR_PROPOSAL_LIFETIME);
        if (input.eta != 0 && input.eta > expiresOn) revert EBadValue();
        if (input.txExpiresOn != 0 && input.txExpiresOn < input.eta) revert EBadValue();

        ProposalCore storage p = _proposals[proposalId];
        p.proposer = msg.sender;
        p.createdOn = now40;
        p.eta = input.eta;
        p.txExpiresOn = input.txExpiresOn;
        p.meta = _packMeta(len, input.proposalType, false);
        p.approvals = 0;
        p.linkProtocol = input.linkProtocol;
        p.metadataHash = input.metadataHash;

        _storeActionHashes(proposalId, actionHashes, len);

        emit ProposalCreated(
            proposalId,
            msg.sender,
            input.eta,
            input.txExpiresOn,
            expiresOn,
            uint8(len),
            input.linkProtocol,
            input.metadataHash
        );
    }

// Remember: anything that is "privileged" goes into the privileged section.
// This is the "ECOSYSTEM CONTRACT PRIVILEGE FUNCTIONALITY" section, above.
// For example, any external function that is gated only to be fully executed
// by certain privileged users or privileged contexts.
    function voteYes(
        uint256 proposalId
    ) external onlyGrantorSeat returns (uint16 approvals) {
        if (_seatActive[msg.sender] != 2) revert ESeatNotActive();

        ProposalCore storage p = _proposals[proposalId];
        uint8 meta = p.meta;
        if (p.proposer == address(0)) revert ENotProposed();
        if (_executed(meta)) revert EExists();
        if (uint40(block.timestamp) > p.createdOn + uint40(GRANTOR_PROPOSAL_LIFETIME)) revert EExpired();

        uint8 seat = _seatIndexPlusOne(msg.sender);
        unchecked {
            seat -= 1;
        }
        if (_votedBySeat[proposalId][seat] == 2) revert EExists();
        _votedBySeat[proposalId][seat] = 2;

        approvals = p.approvals + 1;
        p.approvals = approvals;

        emit ProposalYesVote(proposalId, msg.sender, approvals);
    }

    function removeVote(
        uint256 proposalId
    ) external onlyGrantorSeat returns (uint16 approvals) {
        if (_seatActive[msg.sender] != 2) revert ESeatNotActive();

        ProposalCore storage p = _proposals[proposalId];
        uint8 meta = p.meta;
        if (p.proposer == address(0)) revert ENotProposed();
        if (_executed(meta)) revert EExists();
        if (uint40(block.timestamp) > p.createdOn + uint40(GRANTOR_PROPOSAL_LIFETIME)) revert EExpired();

        uint8 seat = _seatIndexPlusOne(msg.sender);
        unchecked {
            seat -= 1;
        }
        if (_votedBySeat[proposalId][seat] != 2) revert EBadValue();
        _votedBySeat[proposalId][seat] = 1;

        approvals = p.approvals - 1;
        p.approvals = approvals;

        emit ProposalYesVote(proposalId, msg.sender, approvals);
    }

    function registerSeat() external onlyGrantorSeat {
        if (_seatActive[msg.sender] == 2) revert EExists();
        _seatActive[msg.sender] = 2;
        emit GrantorWhitelistAccepted(msg.sender);
    }

    function disagree(
        uint256 proposalId,
        bytes32 reason
    ) external onlyGrantorSeat {
        ProposalCore storage p = _proposals[proposalId];
        if (p.proposer == address(0)) revert ENotProposed();

        // No state change is allowed for "disagree".
        emit ProposalDisagree(proposalId, msg.sender, reason);
    }

    function execute(
        uint256 proposalId,
        address[] calldata targets,
        uint96[] calldata values,
        bytes[] calldata datas
    ) external returns (bytes[] memory rets) {
        ProposalCore storage p = _proposals[proposalId];
        uint8 meta = p.meta;
        if (p.proposer == address(0)) revert ENotProposed();
        if (_executed(meta)) revert EExists();
        if (p.approvals < GRANTOR_EXECUTE_THRESHOLD) revert ENotEnoughVotes();

        uint40 now40 = uint40(block.timestamp);
        if (now40 > p.createdOn + uint40(GRANTOR_PROPOSAL_LIFETIME + GRANTOR_EXECUTION_GRACE)) revert EExpired();
        if (p.eta != 0 && now40 < p.eta) revert ENotExecutableYet();
        if (p.txExpiresOn != 0 && now40 > p.txExpiresOn) revert EExpired();

        uint256 len = targets.length;
        if (len != _actionCount(meta)) revert EBadArrayLength();
        if (len != values.length || len != datas.length) revert EBadArrayLength();

        p.meta = _packMeta(_actionCount(meta), _proposalType(meta), true);

        rets = new bytes[](len);
        uint256 i;
        uint256 proposalType = _proposalType(meta);
        if (proposalType == PROPOSAL_TYPE_NATIVE) {
            if (_globals.nativeExecLock == 2) revert EReentrant();
            _globals.nativeExecLock = 2;
            while (i != len) {
                rets[i] = _executeAction(
                    proposalId,
                    i,
                    targets[i],
                    values[i],
                    datas[i],
                    proposalType
                );

                unchecked { ++i; }
            }
            _globals.nativeExecLock = 1;
        } 
        else {
            while (i != len) {
                rets[i] = _executeAction(
                    proposalId,
                    i,
                    targets[i],
                    values[i],
                    datas[i],
                    proposalType
                );

                unchecked { ++i; }
            }
        }

        emit ProposalExecuted(proposalId);
    }

    function daoSetProposalFee(uint96 newFee) external onlySelf {
        _proposalFeeByToken[address(0)] = newFee;
        emit ProposalFeeChanged(newFee);
    }

    function daoSetProposalFeeToken(address token, uint96 newFee) external onlySelf {
        _proposalFeeByToken[token] = newFee;
        emit ProposalFeeTokenChanged(token, newFee);
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
        external onlySelf
    {
        if (to == address(0)) revert ENullAddress();
        (bool ok, ) = to.call{value: amount}("");
        if (!ok) revert EBadValue();
        emit EmergencyDisbursed(address(0), to, amount);
    }

    function daoAcceptGrantorOwnership(address grantor) external onlySelf {
        if (grantor == address(0)) revert ENullAddress();
        IGrantorOwnership(grantor).acceptOwnership();
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

    /***************************************************************************
     *
     * Other proposed internal functions
     *
     **************************************************************************/
    receive() external payable {}

    fallback() external payable {}
}
