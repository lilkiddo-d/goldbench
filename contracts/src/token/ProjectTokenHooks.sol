// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";
import {GoldbenchAccess} from "../access/GoldbenchAccess.sol";
import {IProjectTokenHooks, ISignalEngine} from "../interfaces/IGoldbench.sol";

/// @title ProjectTokenHooks
/// @notice Everything that touches the (separately launched) $GBEN token. NO token is deployed by this project.
///         `setProjectToken` can be called exactly once by the admin (the Timelock). Until then every token feature
///         reverts with `TokenNotSet` and the rest of the protocol runs normally.
///
///         1. Fee rebate: FeeCollector forwards `rebateBps` of management-fee vault shares here; they are streamed
///            pro-rata to $GBEN stakers (MasterChef-style accumulator per vault).
///         2. Parameter votes: stakers propose a SignalEngine parameter change; the value must pass
///            `SignalEngine.validateParam` (hard bounds). Stake-weighted vote; votes lock stake until the vote ends
///            (no double voting by moving tokens). A passing vote is *scheduled* on the 48h Timelock, where the owner
///            multisig can still cancel it, and anyone can execute it after the delay.
contract ProjectTokenHooks is GoldbenchAccess, ReentrancyGuard, IProjectTokenHooks {
    using SafeERC20 for IERC20;

    uint256 internal constant ACC = 1e36;
    uint256 public constant MAX_VAULTS = 8;

    struct Proposal {
        uint8 paramId;
        uint256 value;
        address proposer;
        uint64 start;
        uint64 end;
        uint256 forVotes;
        uint256 againstVotes;
        uint256 quorumVotes;
        bool queued;
    }

    address public projectToken;
    ISignalEngine public immutable engine;
    TimelockController public immutable timelock;
    address public feeCollector;

    uint256 public totalStaked;
    mapping(address user => uint256) public staked;
    mapping(address user => uint64) public lockedUntil;

    address[] internal _vaults;
    mapping(address vault => bool) public isVault;
    mapping(address vault => uint256) public accRebatePerStake;
    mapping(address vault => mapping(address user => uint256)) public rebateDebt;
    mapping(address vault => mapping(address user => uint256)) public pendingRebate;

    uint256 public proposalThreshold = 1e18; // bounds set in setter
    uint64 public votingPeriod = 3 days;
    uint16 public quorumBps = 1000; // 10% of stake at proposal creation
    uint256 public proposalCount;
    mapping(uint256 id => Proposal) public proposals;
    mapping(uint256 id => mapping(address => bool)) public hasVoted;

    event ProjectTokenSet(address indexed token);
    event FeeCollectorSet(address indexed feeCollector);
    event VaultAdded(address indexed vault);
    event Staked(address indexed user, uint256 amount);
    event Unstaked(address indexed user, uint256 amount);
    event RebateNotified(address indexed vault, uint256 amount, uint256 accPerStake);
    event RebateClaimed(address indexed user, address indexed vault, uint256 amount);
    event GovernanceParamsSet(uint256 threshold, uint64 votingPeriod, uint16 quorumBps);
    event Proposed(uint256 indexed id, address indexed proposer, uint8 paramId, uint256 value, uint64 end);
    event Voted(uint256 indexed id, address indexed voter, bool support, uint256 weight);
    event Queued(uint256 indexed id, bytes32 operationId, uint256 eta);

    error TokenNotSet();
    error TokenAlreadySet();
    error NotFeeCollector();
    error UnknownVault(address vault);
    error TooManyVaults();
    error ZeroAmount();
    error StakeLocked(uint64 until);
    error InsufficientStake();
    error BelowThreshold();
    error VotingClosed();
    error AlreadyVoted();
    error VotingOpen();
    error ProposalFailed();
    error AlreadyQueued();
    error NoStakers();

    constructor(address admin, ISignalEngine engine_, TimelockController timelock_) GoldbenchAccess(admin) {
        if (address(engine_) == address(0) || address(timelock_) == address(0)) revert ZeroAddress();
        engine = engine_;
        timelock = timelock_;
    }

    modifier tokenLive() {
        if (projectToken == address(0)) revert TokenNotSet();
        _;
    }

    // ----------------------------- admin -----------------------------

    /// @notice One-shot. Called by the owner through the Timelock once $GBEN exists on the launchpad.
    function setProjectToken(address token) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (projectToken != address(0)) revert TokenAlreadySet();
        if (token == address(0)) revert ZeroAddress();
        projectToken = token;
        emit ProjectTokenSet(token);
    }

    function setFeeCollector(address fc) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (fc == address(0)) revert ZeroAddress();
        feeCollector = fc;
        emit FeeCollectorSet(fc);
    }

    bytes32 public constant REGISTRAR_ROLE = keccak256("REGISTRAR_ROLE");

    function addVault(address vault) external onlyRole(REGISTRAR_ROLE) {
        if (vault == address(0)) revert ZeroAddress();
        if (isVault[vault]) return;
        if (_vaults.length >= MAX_VAULTS) revert TooManyVaults();
        isVault[vault] = true;
        _vaults.push(vault);
        emit VaultAdded(vault);
    }

    function setGovernanceParams(uint256 threshold, uint64 period, uint16 quorum)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        _checkBounds(period, 1 days, 14 days);
        _checkBounds(quorum, 100, 5000);
        if (threshold == 0) revert ZeroAmount();
        proposalThreshold = threshold;
        votingPeriod = period;
        quorumBps = quorum;
        emit GovernanceParamsSet(threshold, period, quorum);
    }

    function vaults() external view returns (address[] memory) {
        return _vaults;
    }

    // ----------------------------- staking + rebates -----------------------------

    function stake(uint256 amount) external nonReentrant tokenLive whenNotPaused {
        if (amount == 0) revert ZeroAmount();
        _settle(msg.sender);
        staked[msg.sender] += amount;
        totalStaked += amount;
        _resetDebt(msg.sender);
        emit Staked(msg.sender, amount);
        IERC20(projectToken).safeTransferFrom(msg.sender, address(this), amount);
    }

    /// @notice Unstaking is allowed while paused (users can always exit) but not while a cast vote is open.
    function unstake(uint256 amount) external nonReentrant tokenLive {
        if (amount == 0) revert ZeroAmount();
        if (block.timestamp < lockedUntil[msg.sender]) revert StakeLocked(lockedUntil[msg.sender]);
        if (amount > staked[msg.sender]) revert InsufficientStake();
        _settle(msg.sender);
        staked[msg.sender] -= amount;
        totalStaked -= amount;
        _resetDebt(msg.sender);
        emit Unstaked(msg.sender, amount);
        IERC20(projectToken).safeTransfer(msg.sender, amount);
    }

    function notifyRebate(address vault, uint256 amount) external {
        if (msg.sender != feeCollector) revert NotFeeCollector();
        if (!isVault[vault]) revert UnknownVault(vault);
        if (totalStaked == 0) revert NoStakers();
        accRebatePerStake[vault] += (amount * ACC) / totalStaked;
        emit RebateNotified(vault, amount, accRebatePerStake[vault]);
    }

    function claimRebate(address vault) external nonReentrant returns (uint256 amount) {
        if (!isVault[vault]) revert UnknownVault(vault);
        _settle(msg.sender);
        _resetDebt(msg.sender);
        amount = pendingRebate[vault][msg.sender];
        if (amount == 0) return 0;
        pendingRebate[vault][msg.sender] = 0;
        emit RebateClaimed(msg.sender, vault, amount);
        IERC20(vault).safeTransfer(msg.sender, amount);
    }

    function claimable(address vault, address user) external view returns (uint256) {
        uint256 accrued = (staked[user] * accRebatePerStake[vault]) / ACC;
        return pendingRebate[vault][user] + accrued - rebateDebt[vault][user];
    }

    function _settle(address user) internal {
        uint256 s = staked[user];
        uint256 n = _vaults.length;
        for (uint256 i; i < n; ++i) {
            address v = _vaults[i];
            uint256 accrued = (s * accRebatePerStake[v]) / ACC;
            uint256 debt = rebateDebt[v][user];
            if (accrued > debt) pendingRebate[v][user] += accrued - debt;
        }
    }

    function _resetDebt(address user) internal {
        uint256 s = staked[user];
        uint256 n = _vaults.length;
        for (uint256 i; i < n; ++i) {
            address v = _vaults[i];
            rebateDebt[v][user] = (s * accRebatePerStake[v]) / ACC;
        }
    }

    // ----------------------------- parameter votes -----------------------------

    function propose(uint8 paramId, uint256 value) external tokenLive whenNotPaused returns (uint256 id) {
        if (staked[msg.sender] < proposalThreshold) revert BelowThreshold();
        engine.validateParam(paramId, value); // hard bounds enforced up-front
        id = ++proposalCount;
        uint64 end = uint64(block.timestamp) + votingPeriod;
        proposals[id] = Proposal({
            paramId: paramId,
            value: value,
            proposer: msg.sender,
            start: uint64(block.timestamp),
            end: end,
            forVotes: 0,
            againstVotes: 0,
            quorumVotes: (totalStaked * quorumBps) / 10_000,
            queued: false
        });
        emit Proposed(id, msg.sender, paramId, value, end);
    }

    function vote(uint256 id, bool support) external tokenLive whenNotPaused {
        Proposal storage p = proposals[id];
        if (p.end == 0 || block.timestamp >= p.end) revert VotingClosed();
        if (hasVoted[id][msg.sender]) revert AlreadyVoted();
        uint256 w = staked[msg.sender];
        if (w == 0) revert InsufficientStake();
        hasVoted[id][msg.sender] = true;
        if (lockedUntil[msg.sender] < p.end) lockedUntil[msg.sender] = p.end;
        if (support) p.forVotes += w;
        else p.againstVotes += w;
        emit Voted(id, msg.sender, support, w);
    }

    /// @notice Schedules a passed proposal on the Timelock (requires PROPOSER_ROLE there). Re-validated against
    ///         bounds at execution time by SignalEngine.setParam.
    function queue(uint256 id) external tokenLive whenNotPaused returns (bytes32 opId) {
        Proposal storage p = proposals[id];
        if (p.end == 0) revert ProposalFailed();
        if (block.timestamp < p.end) revert VotingOpen();
        if (p.queued) revert AlreadyQueued();
        if (p.forVotes <= p.againstVotes || p.forVotes < p.quorumVotes || p.forVotes == 0) revert ProposalFailed();
        p.queued = true;
        bytes memory data = abi.encodeCall(ISignalEngine.setParam, (p.paramId, p.value));
        bytes32 salt = keccak256(abi.encode(address(this), id));
        uint256 delay = timelock.getMinDelay();
        opId = timelock.hashOperation(address(engine), 0, data, bytes32(0), salt);
        emit Queued(id, opId, block.timestamp + delay);
        timelock.schedule(address(engine), 0, data, bytes32(0), salt, delay);
    }
}
