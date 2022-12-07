//SPDX-License-Identifier: GNU GPLv3
pragma solidity ^0.8.2;

import "@openzeppelin/contracts/access/Ownable.sol";

//@author Nethny
contract Distribution is Ownable {
    struct TeamMember {
        uint256 awardsAddress;
        address[] addresses;
        uint256 interest;
        uint256 shift; //Shift = 10**x interest = interest/shift
        bool choice; // 1- Receiving an award in tokens 0- Receiving an award in usd
        bool immutability;
    }

    address public Root;

    mapping(string => TeamMember) public teamTable;
    string[] public Team;

    function addNewTeamMember(
        string calldata Name,
        address _address,
        uint256 _interest,
        uint256 _shift,
        bool _immutability
    ) public onlyOwner {
        require(teamTable[Name].addresses.length == 0);

        teamTable[Name].addresses.push(_address);
        teamTable[Name].interest = _interest;
        teamTable[Name].shift = _shift;
        teamTable[Name].immutability = _immutability;

        Team.push(Name);
    }

    function changeTeamMember(
        string calldata Name,
        uint256 _interest,
        uint256 _shift,
        bool _immutability
    ) public onlyOwner {
        require(teamTable[Name].immutability == false);

        teamTable[Name].interest = _interest;
        teamTable[Name].shift = _shift;
        teamTable[Name].immutability = _immutability;
    }

    modifier onlyTeamMember(string calldata Name) {
        bool flag = false;
        for (uint256 i = 0; i < teamTable[Name].addresses.length; i++) {
            if (teamTable[Name].addresses[i] == msg.sender) {
                flag = true;
            }
        }

        require(flag);
        _;
    }

    function choose(string calldata Name, bool _choice)
        public
        onlyTeamMember(Name)
    {
        teamTable[Name].choice = _choice;
    }

    function addNewAddressTeam(string calldata Name, address _newAddress)
        public
        onlyTeamMember(Name)
    {
        teamTable[Name].addresses.push(_newAddress);
    }

    function chooseAddressTeam(string calldata Name, uint256 _choice)
        public
        onlyTeamMember(Name)
    {
        require(_choice < teamTable[Name].addresses.length);
        teamTable[Name].awardsAddress = _choice;
    }

    function getTeam() public view returns (string[] memory) {
        return Team;
    }

    function getTeamMember(string calldata name)
        public
        view
        returns (TeamMember memory)
    {
        return teamTable[name];
    }

    /// ====================================================== -Referal- ======================================================

    struct Member {
        address owner;
        uint256 interest;
        uint256 shift;
    }

    mapping(address => Member) public memberTable;

    function getMember(address member) public view returns (Member memory) {
        return memberTable[member];
    }

    function approveNewWallet(address _owner) public {
        require(memberTable[msg.sender].owner == address(0));
        require(msg.sender != _owner);
        memberTable[msg.sender].owner = _owner;
        memberTable[msg.sender].interest = 3;
        memberTable[msg.sender].shift = 100;

        refferalOwnerTable[_owner].members.push(msg.sender);
    }

    function setOwners(address[] calldata members, address _owner)
        public
        onlyOwner
    {
        for (uint256 i = 0; i < members.length; i++) {
            if (memberTable[members[i]].owner != address(0)) {
                address owner = memberTable[members[i]].owner;
                uint256 length = refferalOwnerTable[owner].members.length;
                for (uint256 j = 0; j < length; j++) {
                    if (refferalOwnerTable[owner].members[j] == members[i]) {
                        refferalOwnerTable[owner].members[
                            j
                        ] = refferalOwnerTable[owner].members[length - 1];

                        refferalOwnerTable[owner].members.pop();
                    }
                }
            }

            memberTable[members[i]].owner = _owner;

            refferalOwnerTable[_owner].members.push(members[i]);
        }
    }

    function changeMember(
        address member,
        address _owner,
        uint256 _interest,
        uint256 _shift
    ) public onlyOwner {
        memberTable[member].owner = _owner;
        memberTable[member].interest = _interest;
        memberTable[member].shift = _shift;
    }

    //Refferal owners part

    struct ReferralOwner {
        uint256 awardsAddress;
        address[] addresses;
        address[] members;
    }

    mapping(address => ReferralOwner) public refferalOwnerTable;

    function getOwnerMember(address member)
        public
        view
        returns (ReferralOwner memory)
    {
        return refferalOwnerTable[member];
    }

    function addNewAddressReferral(address _newAddress) public {
        require(refferalOwnerTable[msg.sender].addresses.length < 100);
        refferalOwnerTable[msg.sender].addresses.push(_newAddress);
    }

    function delAddressReferral(address _address) public {
        for (
            uint256 i = 0;
            i < refferalOwnerTable[msg.sender].addresses.length;
            i++
        ) {
            if (refferalOwnerTable[msg.sender].addresses[i] == _address) {
                refferalOwnerTable[msg.sender].addresses[
                    i
                ] = refferalOwnerTable[msg.sender].addresses[
                    refferalOwnerTable[msg.sender].addresses.length - 1
                ];
                refferalOwnerTable[msg.sender].addresses.pop();
                break;
            }
        }
    }

    function chooseAddressReferral(uint256 _choice) public {
        require(_choice < refferalOwnerTable[msg.sender].addresses.length);
        refferalOwnerTable[msg.sender].awardsAddress = _choice;
    }

    function changeMembers(
        address _owner,
        uint256 _interest,
        uint256 _shift
    ) public onlyOwner {
        address[] memory members = refferalOwnerTable[_owner].members;
        for (uint256 i = 0; i < members.length; i++) {
            memberTable[members[i]].interest = _interest;
            memberTable[members[i]].shift = _shift;
        }
    }
}
