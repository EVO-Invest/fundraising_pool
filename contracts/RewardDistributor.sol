//SPDX-License-Identifier: GNU GPLv3
pragma solidity ^0.8.2;

import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";


import "./UnionWallet.sol";
import "./Ranking.sol";

// Referrals store information about referrals.
contract RewardDistributor is Initializable, OwnableUpgradeable {
    address gateway;
    UnionWallet unionwallet;
    Ranking ranking;

    uint16 defaultReferralComission;
    uint16 denominator;

    struct ReferralComissionInfo {
        // Comission which is held from the clients referred by me by default.
        // Number as a nominator for 1000 with denom. So 50 = 5%.
        uint16 comissionOverride;

        // Comission which is held from this particular client.
        // Number as a nominator for 1000 with denom. So 50 = 5%.
        // uint16 comissionOverride;

        // Who invited the user. Should be a top-level wallet.
        address referrer;
    }

    enum TeamMemberRewardTypeChoice { STABLE, TOKEN }

    struct TeamMemberRewardInfo {
        address identity;

        uint16 comission;
        TeamMemberRewardTypeChoice rewardTypeChoice;
    }

    enum ComissionPlacement { STABLE_POST_FUND_CLOSE, STABLE_POST_DISTRIBUTION, TOKEN }

    mapping(address => ReferralComissionInfo) refInfos;
    TeamMemberRewardInfo[] team;
    mapping(address => TeamMemberRewardInfo[]) teamSnapshots;  // per BOP

    modifier fromTrustedSource() {
        require(msg.sender == gateway || msg.sender == owner(),
                "Only messages from gateways are accepted");
        _;
    }

    function initialize(address _gateway, UnionWallet _unionwallet, Ranking _ranking)
        external
        initializer
    {
        __Ownable_init();

        gateway = _gateway;
        unionwallet = _unionwallet;
        ranking = _ranking;
        defaultReferralComission = 30;  // 3%
        denominator = 1000;
    }

    function createTeamSnapshot() public {
        address bop = msg.sender;
        for (uint256 i = 0; i < team.length; ++i) {
            teamSnapshots[bop].push(team[i]);
        }
    }

    function setReferral(address user, address referral) public fromTrustedSource {
        refInfos[unionwallet.resolveIdentity(user)] = ReferralComissionInfo(0, unionwallet.resolveIdentity(referral));
    }

    function calculateComissions(address user, uint256 depositAmount) public view
            returns (
                ComissionPlacement[] memory placements,
                address[] memory addresses,
                uint256[] memory amounts
            ) {
        user = unionwallet.resolveIdentity(user);
        TeamMemberRewardInfo[] storage teamSnapshot = teamSnapshots[msg.sender];

        uint256 index = 0;
        placements = new ComissionPlacement[](2 + teamSnapshot.length);
        addresses = new address[](placements.length);
        amounts = new uint256[](placements.length);

        // Total amount of comissions held.
        uint256 currentUsersComission = depositAmount * ranking.getParRankOfUser(user)[2] / 100;
        // This is to track deductions;
        uint256 commission = currentUsersComission;

        address referrer = refInfos[user].referrer;
        bool isNormalReferrer = (referrer == address(0x0)) || (refInfos[referrer].comissionOverride == 0);
        referrer = (referrer == address(0x0)) ? owner() : referrer;
        bool isNormalUser = (ranking._rankTable(user) == 0);
        
        // Referrer receive their share of comission first.
        uint256 referrerComission = depositAmount *
            (isNormalReferrer ? defaultReferralComission : refInfos[referrer].comissionOverride) /
            denominator;

        // If the referrer is special and user is special referrer's comission is decuded
        // by the amount of difference between normal and not normal user
        if (!isNormalReferrer && !isNormalUser) {
            // we need currentUsersComission as we are using commission to avoid overspending.
            uint256 normalUsersCommission = depositAmount * ranking.getParRankOfUser(address(0x0))[2] / 100;
            if (normalUsersCommission > currentUsersComission) {
                uint256 referrerComissionDeduction = normalUsersCommission - currentUsersComission;
                if (referrerComission < referrerComissionDeduction) {
                    referrerComission = 0;
                } else {
                    referrerComission -= referrerComissionDeduction;
                }
            }
        }

        if (referrerComission > commission) { referrerComission = commission; }
        commission -= referrerComission;
        placements[index] = ComissionPlacement.STABLE_POST_DISTRIBUTION;
        addresses[index] = referrer;
        amounts[index] = referrerComission;
        index += 1;

        // Team receives their shares:
        for (uint256 i = 0; i < teamSnapshot.length; ++i) {
            uint256 teamMemberComission = depositAmount * teamSnapshot[i].comission / denominator;
            if (teamMemberComission > commission) { teamMemberComission = commission; }
            commission -= teamMemberComission;
            placements[index] = (
                teamSnapshot[i].rewardTypeChoice == TeamMemberRewardTypeChoice.STABLE
                    ? ComissionPlacement.STABLE_POST_DISTRIBUTION
                    : ComissionPlacement.TOKEN
            );
            addresses[index] = teamSnapshot[i].identity;
            amounts[index] = teamMemberComission;
            index += 1;
        }

        // Remaining goes to owner
        placements[index] = ComissionPlacement.STABLE_POST_FUND_CLOSE;
        addresses[index] = owner();
        amounts[index] = commission;
        index += 1;
    }

}