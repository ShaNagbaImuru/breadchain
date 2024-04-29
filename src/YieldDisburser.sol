// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {OwnableUpgradeable} from "openzeppelin-contracts-upgradeable/contracts/access/OwnableUpgradeable.sol";
import {Checkpoints} from "openzeppelin-contracts-upgradeable/lib/openzeppelin-contracts/contracts/utils/structs/Checkpoints.sol";
import {Time} from "openzeppelin-contracts/contracts/utils/types/Time.sol";
import {Bread} from "../lib/bread-token-v2/src/Bread.sol";

error AlreadyClaimed();

contract YieldDisburser is OwnableUpgradeable {
    address[] public breadchainProjects;
    address[] public queuedProjectsForAddition;
    address[] public queuedProjectsForRemoval;
    address[] public breadchainVoters;
    Bread public breadToken;
    uint48 public lastClaimedTimestamp;
    uint256 public lastClaimedBlocknumber;
    uint48 public minimumTimeBetweenClaims;
    uint256 public pointsMax;
    mapping(address => uint256[]) public holderToDistribution;
    mapping(address => uint256) public holderToDistributionTotal;
    uint256 public constant PRECISION = 1e18;

    event BaseYieldDistributed(uint256 amount, address project);
    event ProjectAdded(address project);
    event ProjectRemoved(address project);

    error EndAfterCurrentBlock();
    error IncorrectNumberOfProjects();
    error InvalidSignature();
    error MustBeGreaterThanZero();
    error VotePointsTooLarge();
    error NoCheckpointsForAccount();
    error StartMustBeBeforeEnd();
    error YieldNotResolved();
    error YieldTooLow(uint256);
    error ProjectNotFound();
    error ProjectExistsOrAlreadyQueued();

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(address breadAddress, address[] memory _breadchainProjects) public initializer {
        breadToken = Bread(breadAddress);
        breadchainProjects = new address[](_breadchainProjects.length);
        for (uint256 i; i < _breadchainProjects.length; ++i) {
            breadchainProjects[i] = _breadchainProjects[i];
        }
        pointsMax = 100000;
        __Ownable_init(msg.sender);
    }

    /**
     *
     *          Public Functions         *
     *
     */
    function distributeYield() public {
        (bool _resolved, /* bytes memory _data */ ) = resolveYieldDistribution();
        if (!_resolved) revert YieldNotResolved();

        breadToken.claimYield(breadToken.yieldAccrued(), address(this));
        uint256 breadchainProjectsLength = breadchainProjects.length;
        (uint256[] memory projectDistributions, uint256 totalVotes) =
            _commitVotedDistribution(breadchainProjectsLength);
        if (totalVotes == 0) {
            projectDistributions = new uint256[](breadchainProjectsLength);
            for (uint256 i; i < breadchainProjectsLength; ++i) {
                projectDistributions[i] = 1;
            }
            totalVotes = breadchainProjectsLength;
        }


        lastClaimedTimestamp = Time.timestamp();
        lastClaimedBlocknumber = Time.blockNumber();

        uint256 halfBalance = breadToken.balanceOf(address(this)) / 2;
        uint256 baseSplit = halfBalance / breadchainProjectsLength;
        for (uint256 i; i < breadchainProjectsLength; ++i) {
            uint256 votedSplit = halfBalance * (projectDistributions[i] * PRECISION / totalVotes) / PRECISION;
            breadToken.transfer(breadchainProjects[i], votedSplit + baseSplit);
        }
        _updateBreadchainProjects();
    }

    function castVote(uint256[] calldata points) public {
        _castVote(points, msg.sender);
    }

    /**
     *
     *           View Functions          *
     *
     */
    function resolveYieldDistribution() public view returns (bool, bytes memory) {
        uint48 _now = Time.timestamp();
        uint256 balance = (breadToken.balanceOf(address(this)) + breadToken.yieldAccrued());
        if (balance < breadchainProjects.length) revert YieldTooLow(balance);
        if (_now < lastClaimedTimestamp + minimumTimeBetweenClaims) {
            revert AlreadyClaimed();
        }
        bytes memory ret = abi.encodePacked(this.distributeYield.selector);
        return (true, ret);
    }

    function getVotingPowerForPeriod(uint256 start, uint256 end, address account) external view returns (uint256) {
        if (start > end) revert StartMustBeBeforeEnd();
        if (end > Time.blockNumber()) revert EndAfterCurrentBlock();
        uint32 latestCheckpointPos = breadToken.numCheckpoints(account);
        if (latestCheckpointPos == 0) revert NoCheckpointsForAccount();
        latestCheckpointPos--; // Subtract 1 for 0-indexed array
        Checkpoints.Checkpoint208 memory intervalEnd = breadToken.checkpoints(account, latestCheckpointPos);
        uint48 prevKey = intervalEnd._key;
        uint256 intervalEndValue = intervalEnd._value;
        uint256 votingPower = intervalEndValue * ((end) - prevKey);
        if (latestCheckpointPos == 0) {
            if (end == prevKey) {
                // If the latest checkpoint is exactly at the end of the interval, return the value at that checkpoint
                return intervalEndValue;
            } else {
                return votingPower; // Otherwise, return the voting power calculated above, which is the value at the latest checkpoint multiplied by the length of the interval
            }
        }
        uint256 interval_voting_power;
        uint48 key;
        uint256 value;
        Checkpoints.Checkpoint208 memory checkpoint;
        // Iterate through checkpoints in reverse order, starting one before the latest checkpoint because we already handled it above
        for (uint32 i = latestCheckpointPos - 1; i >= 0; i--) {
            checkpoint = breadToken.checkpoints(account, i);
            key = checkpoint._key;
            value = checkpoint._value;
            interval_voting_power = value * (prevKey - key);
            if (key <= start) {
                votingPower += interval_voting_power;
                break;
            } else {
                votingPower += interval_voting_power;
            }
            prevKey = key;
        }
        return votingPower;
    }

    /**
     *
     *         Internal Functions        *
     *
     */
    function _castVote(uint256[] calldata points, address holder) internal {
        uint256 length = breadchainProjects.length;
        if (points.length != length) revert IncorrectNumberOfProjects();

        if (holderToDistribution[holder].length > 0) {
            delete holderToDistribution[holder];
        } else {
            breadchainVoters.push(holder);
        }
        holderToDistribution[holder] = points;
        uint256 total;
        for (uint256 i; i < length; ++i) {
            if (points[i] > pointsMax) revert VotePointsTooLarge();
            total += points[i];
        }
        holderToDistributionTotal[holder] = total;
    }

    function _updateBreadchainProjects() internal {
        for (uint256 i; i < queuedProjectsForAddition.length; ++i) {
            address project = queuedProjectsForAddition[i];
            breadchainProjects.push(project);
            emit ProjectAdded(project);
        }
        delete queuedProjectsForAddition;
        address[] memory oldBreadChainProjects = breadchainProjects;
        delete breadchainProjects;
        for (uint256 i; i < oldBreadChainProjects.length; ++i) {
            address project = oldBreadChainProjects[i];
            bool remove;
            for (uint256 j; j < queuedProjectsForRemoval.length; ++j) {
                if (project == queuedProjectsForRemoval[j]) {
                    remove = true;
                    break;
                }
            }
            if (!remove) {
                breadchainProjects.push(project);
            }
        }
        delete queuedProjectsForRemoval;
    }

    function _commitVotedDistribution(uint256 projectCount) internal returns (uint256[] memory, uint256) {
        uint256 totalVotes;
        uint256[] memory projectDistributions = new uint256[](projectCount);

        for (uint256 i; i < breadchainVoters.length; ++i) {
            address voter = breadchainVoters[i];
            uint256 voterPower = this.getVotingPowerForPeriod(lastClaimedBlocknumber, Time.blockNumber(), voter);
            uint256[] memory voterDistribution = holderToDistribution[voter];
            uint256 vote;
            for (uint256 j; j < projectCount; ++j) {
                vote = voterPower * voterDistribution[j] / holderToDistributionTotal[voter];
                projectDistributions[j] += vote;
                totalVotes += vote;
            }
            delete holderToDistribution[voter];
            delete holderToDistributionTotal[voter];
        }

        return (projectDistributions, totalVotes);
    }

    /**
     *
     *        Only Owner Functions       *
     *
     */
    function setMinimumTimeBetweenClaims(uint48 _minimumTimeBetweenClaims) public onlyOwner {
        if (_minimumTimeBetweenClaims == 0) revert MustBeGreaterThanZero();
        minimumTimeBetweenClaims = _minimumTimeBetweenClaims * 1 minutes;
    }

    function setlastClaimedTimestamp(uint48 _lastClaimedTimestamp) public onlyOwner {
        lastClaimedTimestamp = _lastClaimedTimestamp;
    }

    function setLastClaimedBlocknumber(uint256 _lastClaimedBlocknumber) public onlyOwner {
        lastClaimedBlocknumber = _lastClaimedBlocknumber;
    }

    function queueProjectAddition(address project) public onlyOwner {
        for (uint256 i; i < queuedProjectsForAddition.length; ++i) {
            if (queuedProjectsForAddition[i] == project) {
                revert ProjectNotFound();
            }
        }
        for (uint256 i; i < breadchainProjects.length; ++i) {
            if (breadchainProjects[i] == project) {
                revert ProjectExistsOrAlreadyQueued();
            }
        }
        queuedProjectsForAddition.push(project);
    }

    function queueProjectRemoval(address project) public onlyOwner {
        for (uint256 i; i < queuedProjectsForRemoval.length; ++i) {
            if (queuedProjectsForRemoval[i] == project) {
                revert ProjectExistsOrAlreadyQueued();
            }
        }
        for (uint256 i; i < breadchainProjects.length; ++i) {
            if (breadchainProjects[i] == project) {
                queuedProjectsForRemoval.push(project);
                return;
            }
        }
        revert ProjectNotFound();
    }

    function getBreadchainProjectsLength() public view returns (uint256) {
        return breadchainProjects.length;
    }

    function setPointsMax(uint256 _pointsMax) public onlyOwner {
        pointsMax = _pointsMax;
    }
}
