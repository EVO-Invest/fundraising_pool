//SPDX-License-Identifier: GNU GPLv3
pragma solidity ^0.8.2;

import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/ArraysUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/CountersUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/structs/EnumerableSetUpgradeable.sol";

import "./UnionWallet.sol";


// Referrals store information about referrals.
// Inspired by @openzeppelin's ERC20Snapshot.
contract RewardCalcs is Initializable, OwnableUpgradeable {
    using ArraysUpgradeable for uint256[];
    using CountersUpgradeable for CountersUpgradeable.Counter;
    using EnumerableSetUpgradeable for EnumerableSetUpgradeable.AddressSet;

    struct ReferralCommissionInfo {
        // Commission which is held from the clients referred by me by default.
        // Number as a nominator for 1000 with denom. So 50 = 5%.
        uint16 commissionOverride;

        // Commission which is held from this particular client.
        // Number as a nominator for 1000 with denom. So 50 = 5%.
        // uint16 commissionOverride;

        // Who invited the user. Should be a top-level wallet.
        address referrer;
    }

    enum TeamMemberRewardTypeChoice { STABLE, TOKEN }

    struct TeamRewardsSnapshots {
        uint256[] ids;
        uint16[] commissions;
        TeamMemberRewardTypeChoice[] rewardTypeChoices;
    }

    struct TeamRewards {
        uint16 commission;
        TeamMemberRewardTypeChoice rewardTypeChoice;
    }

    address _gateway;
    address _snapshotter;
    UnionWallet _unionwallet;

    uint16 _defaultReferralCommission;
    uint16 public _denominator;
    mapping(address => ReferralCommissionInfo) _refInfos;
    mapping(address => TeamRewards) _teamRewards;
    mapping(address => TeamRewardsSnapshots) _teamRewardsSnapshots;
    EnumerableSetUpgradeable.AddressSet private _team;

    // Snapshot ids increase monotonically, with the first value being 1. An id of 0 is invalid.
    CountersUpgradeable.Counter private _currentSnapshotId;

    function initialize(address gateway, address snapshotter, UnionWallet unionwallet)
        external
        initializer
    {
        __Ownable_init();

        _gateway = gateway;
        _snapshotter = snapshotter;
        _unionwallet = unionwallet;
        _defaultReferralCommission = 30;  // 3%
        _denominator = 1000;
    }

    function setDefaultCommission(uint16 newValue) external onlyOwner {
        require(newValue <= _denominator, "nom>denom");
        _defaultReferralCommission = newValue;
    }

    function setCommissionForReferrer(address referrer, uint16 newValue) external onlyOwner {
        require(newValue <= _denominator, "nom>denom");
        _refInfos[referrer].commissionOverride = newValue;
    }

    function snapshotTeam() public returns (uint256) {
        require(msg.sender == _snapshotter, "not _snapshotter");
        _currentSnapshotId.increment();

        uint256 currentId = _getCurrentSnapshotId();
        return currentId;
    }

    function _getCurrentSnapshotId() internal view virtual returns (uint256) {
        return _currentSnapshotId.current();
    }

    function teamMemberRewardInfoAt(address account, uint256 snapshotId) public view returns (uint16, TeamMemberRewardTypeChoice) {
        (bool snapshotted, uint16 value, TeamMemberRewardTypeChoice rewardTypeChoice) = _valueAt(snapshotId, _teamRewardsSnapshots[account]);

        return snapshotted ? (value, rewardTypeChoice) : (_teamRewards[account].commission, _teamRewards[account].rewardTypeChoice);
    }

    // Making the defaultCommission as a parameter in order to keep all deals with
    // our Ranking system external.
    function calculateReferralsCommission(address depositor, uint256 depositAmount, uint256 commission, uint256 defaultCommission) public view
            returns (uint256, address) {
        address referrer = _refInfos[depositor].referrer;
        if (referrer == address(0x0)) {
            return (0, referrer);
        }
        uint16 commissionOverride = _refInfos[referrer].commissionOverride;
        bool isNormalReferrer = (commissionOverride == 0) || (commissionOverride == _defaultReferralCommission);

        uint256 referrerCommission = depositAmount *
            (isNormalReferrer ? _defaultReferralCommission : commissionOverride) /
            _denominator;
        
        // Some depositors may have 0% commissions. We are not paying to referrers in this case.
        if (referrerCommission < commission) referrerCommission = commission;

        // If the referrer is special and user is special referrer's commission is decuded
        // by the amount of difference between normal and not normal user
        if (!isNormalReferrer) {
            // we need currentUsersCommission as we are using commission to avoid overspending.
            if (defaultCommission > commission) {
                uint256 referrerCommissionDeduction = defaultCommission - commission;
                if (referrerCommission < referrerCommissionDeduction) {
                    referrerCommission = 0;
                } else {
                    referrerCommission -= referrerCommissionDeduction;
                }
            }
        }

        return (referrerCommission, referrer);
    }

    function setReferral(address user, address referral) public {
        require(user != referral, "Self-referring is not allowed");
        require(msg.sender == _gateway || msg.sender == owner(), "setReferral: wrong caller");
        require(_refInfos[user].referrer == address(0x0) || msg.sender == owner(), "onlyOwner can update ref");
        _refInfos[user] = ReferralCommissionInfo(0, referral);
    }

    function _valueAt(uint256 snapshotId, TeamRewardsSnapshots storage snapshots) private view returns (bool, uint16, TeamMemberRewardTypeChoice) {
        require(snapshotId > 0, "ERC20Snapshot: id is 0");
        require(snapshotId <= _getCurrentSnapshotId(), "ERC20Snapshot: nonexistent id");

        // When a valid snapshot is queried, there are three possibilities:
        //  a) The queried value was not modified after the snapshot was taken. Therefore, a snapshot entry was never
        //  created for this id, and all stored snapshot ids are smaller than the requested one. The value that corresponds
        //  to this id is the current one.
        //  b) The queried value was modified after the snapshot was taken. Therefore, there will be an entry with the
        //  requested id, and its value is the one to return.
        //  c) More snapshots were created after the requested one, and the queried value was later modified. There will be
        //  no entry for the requested id: the value that corresponds to it is that of the smallest snapshot id that is
        //  larger than the requested one.
        //
        // In summary, we need to find an element in an array, returning the index of the smallest value that is larger if
        // it is not found, unless said value doesn't exist (e.g. when all values are smaller). Arrays.findUpperBound does
        // exactly this.

        uint256 index = snapshots.ids.findUpperBound(snapshotId);

        if (index == snapshots.ids.length) {
            return (false, 0, TeamMemberRewardTypeChoice.STABLE);
        } else {
            return (true, snapshots.commissions[index], snapshots.rewardTypeChoices[index]);
        }
    }

    /* call it BEFORE doing an actual change! */
    function _updateSnapshot(TeamRewardsSnapshots storage snapshots, uint16 commission, TeamMemberRewardTypeChoice rewardTypeChoice) private {
        /* The comment for future myself how does it work.

        Let's say we have created a snapshot v1. Actually nothing happened.
        v1 is the most recent snapshot.
        If the user wants to get the state at v1, they can just read the most recent value.
        Once the value changed, we need to add it to the snapshot.
        That's it!
        */
        uint256 currentId = _getCurrentSnapshotId();
        if (_lastSnapshotId(snapshots.ids) < currentId) {
            snapshots.ids.push(currentId);
            snapshots.commissions.push(commission);
            snapshots.rewardTypeChoices.push(rewardTypeChoice);
        }
    }

    function _lastSnapshotId(uint256[] storage ids) private view returns (uint256) {
        if (ids.length == 0) {
            return 0;
        } else {
            return ids[ids.length - 1];
        }
    }

    function addTeamMember(address user, uint16 commission, TeamMemberRewardTypeChoice choice) external onlyOwner {
        require(_team.add(user), "Already exists");
        _updateSnapshot(_teamRewardsSnapshots[user], 0, TeamMemberRewardTypeChoice.TOKEN);
        _teamRewards[user] = TeamRewards(commission, choice);
    }
    function updateTeamMember(address user, uint16 commission) external onlyOwner {
        require(_team.contains(user), "Not exists");
        _updateSnapshot(_teamRewardsSnapshots[user], _teamRewards[user].commission, _teamRewards[user].rewardTypeChoice);
        _teamRewards[user].commission = commission;
    }
    function updateMyRewardTypeChoice(TeamMemberRewardTypeChoice choice) external {
        address user = _unionwallet.resolveIdentity(msg.sender);
        require(_team.contains(user), "Not exists");
        _updateSnapshot(_teamRewardsSnapshots[user], _teamRewards[user].commission, _teamRewards[user].rewardTypeChoice);
        _teamRewards[user].rewardTypeChoice = choice;
    }

    function allTeamLength() public view returns (uint256) {
        return _team.length();
    }
    function allTeamAt(uint256 index) public view returns (address) {
        return _team.at(index);
    }
}