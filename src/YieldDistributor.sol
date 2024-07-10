// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {OwnableUpgradeable} from "openzeppelin-contracts-upgradeable/contracts/access/OwnableUpgradeable.sol";
import {Checkpoints} from
    "openzeppelin-contracts-upgradeable/lib/openzeppelin-contracts/contracts/utils/structs/Checkpoints.sol";
import {Bread} from "bread-token/src/Bread.sol";

/**
 * @title Breadchain Yield Distributor
 * @notice Distribute $BREAD yield to eligible member projects based on a voted distribution
 * @author Breadchain Collective
 * @custom:coauthor @RonTuretzky
 * @custom:coauthor bagelface.eth
 * @custom:coauthor prosalads.eth
 * @custom:coauthor kassandra.eth
 * @custom:coauthor theblockchainsocialist.eth
 */
contract YieldDistributor is OwnableUpgradeable {
    // @notice The error emitted when attempting to add a project that is already in the `projects` array
    error AlreadyMemberProject();
    // @notice the error emitted when attemping to vote in the same cycle twice
    error AlreadyVotedInCycle();
    // @notice The error emitted when a user attempts to vote without the minimum required voting power
    error BelowMinRequiredVotingPower();
    // @notice The error emitted when attempting to calculate voting power for a period that has not yet ended
    error EndAfterCurrentBlock();
    // @notice The error emitted when attempting to vote with a point value greater than `pointsMax`
    error ExceedsMaxPoints();
    // @notice The error emitted when attempting to vote with an incorrect number of projects
    error IncorrectNumberOfProjects();
    // @notice The error emitted when attempting to instantiate a variable with a zero value
    error MustBeGreaterThanZero();
    // @notice The error emitted when attempting to add or remove a project that is already queued for addition or removal
    error ProjectAlreadyQueued();
    // @notice The error emitted when attempting to remove a project that is not in the `projects` array
    error ProjectNotFound();
    // @notice The error emitted when attempting to calculate voting power for a period with a start block greater than the end block
    error StartMustBeBeforeEnd();
    // @notice The error emitted when attempting to distribute yield when access conditions are not met
    error YieldNotResolved();
    // @notice The error emitted if a user with zero points attempts to cast votes
    error ZeroVotePoints();

    // @notice The event emitted when an account casts a vote
    event BreadHolderVoted(address indexed account, uint256[] points, address[] projects);
    // @notice The event emitted when a project is added as eligibile for yield distribution
    event ProjectAdded(address project);
    // @notice The event emitted when a project is removed as eligibile for yield distribution
    event ProjectRemoved(address project);
    // @notice The event emitted when yield is distributed
    event YieldDistributed(uint256 yield, uint256 totalVotes, uint256[] projectDistributions);

    // @notice The address of the $BREAD token contract
    Bread public BREAD;
    // @notice The precision to use for calculations
    uint256 public PRECISION;
    // @notice The minimum number of blocks between yield distributions
    uint256 public cycleLength;
    // @notice The maximum number of points a voter can allocate to a project
    uint256 public maxPoints;
    // @notice The minimum required voting power participants must have to cast a vote
    uint256 public minRequiredVotingPower;
    // @notice The block number of the last yield distribution
    uint256 public lastClaimedBlockNumber;
    // @notice The total number of votes cast in the current cycle
    uint256 public currentVotes;
    // @notice Array of projects eligible for yield distribution
    address[] public projects;
    // @notice Array of projects queued for addition to the next cycle
    address[] public queuedProjectsForAddition;
    // @notice Array of projects queued for removal from the next cycle
    address[] public queuedProjectsForRemoval;
    // @notice The voting power allocated to projects by voters in the current cycle
    uint256[] public projectDistributions;
    /* IIUC, `projectDistributions` and `projects` are intended to be kept in sync.
    - This is a somewhat fragile pattern. At the very least, it should be commented and made explicit.
    - It would be better to have a single array with a struct holding the address and uint256. That is
      not gas-optimal, but given that this contract lives on Gnosis I think the balance between code
      quality and gas optimization should tilt heavily towards the former.
    - Even better IMO would be a `mapping(address => uint256)` to track distributions per project.
      That would allow a voting interface that passes votes by address rather than array index, which
      is pretty hard to debug after the fact (e.g. through a chain explorer). The current setup is more
      vulnerable to either of an evil frontend or MEV. Neither of those is a proximate issue, but still.
    */
    // @notice The last block number in which a specified account cast a vote
    mapping(address => uint256) public accountLastVoted;

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(
        address _bread,
        uint256 _precision,
        uint256 _minRequiredVotingPower,
        uint256 _maxPoints,
        uint256 _cycleLength,
        uint256 _lastClaimedBlockNumber,
        address[] memory _projects
    ) public initializer {
        __Ownable_init(msg.sender);

        BREAD = Bread(_bread);
        PRECISION = _precision;
        minRequiredVotingPower = _minRequiredVotingPower;
        maxPoints = _maxPoints;
        cycleLength = _cycleLength;
        lastClaimedBlockNumber = _lastClaimedBlockNumber;

        projectDistributions = new uint256[](_projects.length);
        projects = new address[](_projects.length);
        for (uint256 i; i < _projects.length; ++i) {
            projects[i] = _projects[i];
        }
    }

    /**
     * @notice Returns the current distribution of voting power for projects
     * @return address[] The current eligible member projects
     * @return uint256[] The current distribution of voting power for projects
     */
    function getCurrentVotingDistribution() public view returns (address[] memory, uint256[] memory) {
        return (projects, projectDistributions);
    }

    /**
     * @notice Return the current voting power of a user
     * @param _account Address of the user to return the voting power for
     * @return uint256 The voting power of the user
     */
    function getCurrentVotingPower(address _account) public view returns (uint256) {
        /*
        - This returns the voting power based on the last period, which is intended but may be
          surprising. It would be good to comment this behavior.
        - It also uses `cycleLength` (the minimum time between cycles) for this calculation rather
          than the actual time for the block before the last claimed block. If this is an intentional
          choice it should be explicitly called out, but I think it might make more sense to track the
          last two distribution blocks, rather than just `lastClaimedBlockNumber` here.
        */
        return this.getVotingPowerForPeriod(lastClaimedBlockNumber - cycleLength, lastClaimedBlockNumber, _account);
    }

    /**
     * @notice Return the voting power for a specified user during a specified period of time
     * @param _start Start time of the period to return the voting power for
     * @param _end End time of the period to return the voting power for
     * @param _account Address of user to return the voting power for
     * @return uint256 Voting power of the specified user at the specified period of time
     */
    function getVotingPowerForPeriod(uint256 _start, uint256 _end, address _account) external view returns (uint256) {
        if (_start >= _end) revert StartMustBeBeforeEnd();
        if (_end > block.number) revert EndAfterCurrentBlock();

        // Initialized as the checkpoint count, but later used to track checkpoint index
        uint32 _currentCheckpointIndex = BREAD.numCheckpoints(_account);
        if (_currentCheckpointIndex == 0) return 0;

        // No voting power if the first checkpoint is after the end of the interval
        Checkpoints.Checkpoint208 memory _currentCheckpoint = BREAD.checkpoints(_account, 0);
        if (_currentCheckpoint._key > _end) return 0;

        // Find the latest checkpoint that is within the interval
        do {
            --_currentCheckpointIndex;
            _currentCheckpoint = BREAD.checkpoints(_account, _currentCheckpointIndex);
        } while (_currentCheckpoint._key > _end);

        // Initialize voting power with the latest checkpoint thats within the interval (or nearest to it)
        uint48 _latestKey = _currentCheckpoint._key < _start ? uint48(_start) : _currentCheckpoint._key;
        uint256 _totalVotingPower = _currentCheckpoint._value * (_end - _latestKey);

        if (_latestKey == _start) return _totalVotingPower;

        for (uint32 i = _currentCheckpointIndex; i > 0;) {
            // Latest checkpoint voting power is calculated when initializing `_totalVotingPower`, so we pre-decrement the index here
            _currentCheckpoint = BREAD.checkpoints(_account, --i);

            // Add voting power for the sub-interval to the total
            _totalVotingPower += _currentCheckpoint._value * (_latestKey - _currentCheckpoint._key);

            // At the start of the interval, deduct voting power accrued before the interval and return the total
            if (_currentCheckpoint._key <= _start) {
                _totalVotingPower -= _currentCheckpoint._value * (_start - _currentCheckpoint._key);
                break;
            }

            _latestKey = _currentCheckpoint._key;
        }
        /* It really feels like L170-190 could be unified into a single loop rather than a separate
        step for calculating just the first chunk of voting power.
        */

        return _totalVotingPower;
    }

    /**
     * @notice Determine if the yield distribution is available
     * @dev Resolver function required for Powerpool job registration. For more details, see the Powerpool documentation:
     * @dev https://docs.powerpool.finance/powerpool-and-poweragent-network/power-agent/user-guides-and-instructions/i-want-to-automate-my-tasks/job-registration-guide#resolver-job
     * @return bool Flag indicating if the yield is able to be distributed
     * @return bytes Calldata used by the resolver to distribute the yield
     */
    function resolveYieldDistribution() public view returns (bool, bytes memory) {
        if (
            currentVotes == 0 // No votes were cast
                || block.number < lastClaimedBlockNumber + cycleLength // Already claimed this cycle
                || BREAD.balanceOf(address(this)) + BREAD.yieldAccrued() < projects.length // Yield is insufficient
        ) {
            return (false, new bytes(0));
        } else {
            return (true, abi.encodePacked(this.distributeYield.selector));
        }
    }

    /**
     * @notice Distribute $BREAD yield to projects based on cast votes
     */
    function distributeYield() public {
        (bool _resolved,) = resolveYieldDistribution();
        if (!_resolved) revert YieldNotResolved();

        BREAD.claimYield(BREAD.yieldAccrued(), address(this));
        lastClaimedBlockNumber = block.number;
        /* This is presumably leaving some dust in this contract, which is probably fine but may
        deserve a callout comment.
        */
        uint256 _halfYield = BREAD.balanceOf(address(this)) / 2;
        uint256 _baseSplit = _halfYield / projects.length;

        for (uint256 i; i < projects.length; ++i) {
            uint256 _votedSplit = ((projectDistributions[i] * _halfYield * PRECISION) / currentVotes) / PRECISION;
            BREAD.transfer(projects[i], _votedSplit + _baseSplit);
        }

        _updateBreadchainProjects();

        emit YieldDistributed(_halfYield * 2, currentVotes, projectDistributions);

        delete currentVotes;
        projectDistributions = new uint256[](projects.length);
    }

    /**
     * @notice Cast votes for the distribution of $BREAD yield
     * @param _points List of points as integers for each project
     */
    function castVote(uint256[] calldata _points) public {
        if (accountLastVoted[msg.sender] > lastClaimedBlockNumber) revert AlreadyVotedInCycle();

        uint256 _currentVotingPower = getCurrentVotingPower(msg.sender);

        if (_currentVotingPower < minRequiredVotingPower) revert BelowMinRequiredVotingPower();

        _castVote(msg.sender, _points, _currentVotingPower);
    }

    /**
     * @notice Internal function for casting votes for a specified user
     * @param _account Address of user to cast votes for
     *  /* Unless I'm missing something, calling these basis points is pretty confusing, since that term
     *  usually refers to 1/100th of a percent, which these are not.
     * @param _points Basis points for calculating the amount of votes cast
     * @param _votingPower Amount of voting power being cast
     */
    function _castVote(address _account, uint256[] calldata _points, uint256 _votingPower) internal {
        if (_points.length != projects.length) revert IncorrectNumberOfProjects();

        uint256 _totalPoints;

        for (uint256 i; i < _points.length; ++i) {
            if (_points[i] > maxPoints) revert ExceedsMaxPoints();
            _totalPoints += _points[i];
        }

        if (_totalPoints == 0) revert ZeroVotePoints();

        for (uint256 i; i < _points.length; ++i) {
            projectDistributions[i] += ((_points[i] * _votingPower * PRECISION) / _totalPoints) / PRECISION;
        }

        accountLastVoted[_account] = block.number;
        currentVotes += _votingPower;

        emit BreadHolderVoted(_account, _points, projects);
    }

    /**
     * @notice Internal function for updating the project list
     */
    function _updateBreadchainProjects() internal {
        for (uint256 i; i < queuedProjectsForAddition.length; ++i) {
            address _project = queuedProjectsForAddition[i];

            projects.push(_project);

            emit ProjectAdded(_project);
        }

        address[] memory _oldProjects = projects;
        delete projects;

        for (uint256 i; i < _oldProjects.length; ++i) {
            address _project = _oldProjects[i];
            bool _remove;
            /* Using a mapping would eliminate the need for this inner loop.
            */

            for (uint256 j; j < queuedProjectsForRemoval.length; ++j) {
                if (_project == queuedProjectsForRemoval[j]) {
                    _remove = true;
                    emit ProjectRemoved(_project);
                    break;
                }
            }

            if (!_remove) {
                projects.push(_project);
            }
        }

        delete queuedProjectsForAddition;
        delete queuedProjectsForRemoval;
    }

    /**
     * @notice Queue a new project to be added to the project list
     * @param _project Project to be added to the project list
     */
    function queueProjectAddition(address _project) public onlyOwner {
        for (uint256 i; i < projects.length; ++i) {
            if (projects[i] == _project) {
                revert AlreadyMemberProject();
            }
        }
        /* Arguably this method should check if the project is in the removal queue and remove it from
        there if so. As is, if someone fat-fingers their way into removing a project, there's no way to
        undo that, since a project that is in both the addition and removal queues will end up removed
        no matter what.
        */
        for (uint256 i; i < queuedProjectsForAddition.length; ++i) {
            if (queuedProjectsForAddition[i] == _project) {
                revert ProjectAlreadyQueued();
            }
        }

        queuedProjectsForAddition.push(_project);
    }

    /**
     * @notice Queue an existing project to be removed from the project list
     * @param _project Project to be removed from the project list
     */
    function queueProjectRemoval(address _project) public onlyOwner {
        bool _found = false;
        for (uint256 i; i < projects.length; ++i) {
            if (projects[i] == _project) {
                _found = true;
            }
        }

        /* Just a callout that if this method is altered to check the addition queue, it'll have to
        change this check as well.
        */
        if (!_found) revert ProjectNotFound();

        for (uint256 i; i < queuedProjectsForRemoval.length; ++i) {
            if (queuedProjectsForRemoval[i] == _project) {
                revert ProjectAlreadyQueued();
            }
        }

        queuedProjectsForRemoval.push(_project);
    }

    /**
     * @notice Set a new minimum required voting power a user must have to vote
     * @param _minRequiredVotingPower New minimum required voting power a user must have to vote
     */
    function setMinRequiredVotingPower(uint256 _minRequiredVotingPower) public onlyOwner {
        if (_minRequiredVotingPower == 0) revert MustBeGreaterThanZero();

        minRequiredVotingPower = _minRequiredVotingPower;
    }

    /**
     * @notice Set a new maximum number of points a user can allocate to a project
     * @param _maxPoints New maximum number of points a user can allocate to a project
     */
    function setMaxPoints(uint256 _maxPoints) public onlyOwner {
        if (_maxPoints == 0) revert MustBeGreaterThanZero();

        maxPoints = _maxPoints;
    }

    /**
     * @notice Set a new cycle length in blocks
     * @param _cycleLength New cycle length in blocks
     */
    function setCycleLength(uint256 _cycleLength) public onlyOwner {
        if (_cycleLength == 0) revert MustBeGreaterThanZero();

        cycleLength = _cycleLength;
    }
}
