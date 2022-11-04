//SPDX-License-Identifier: GNU GPLv3
pragma solidity ^0.8.2;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/utils/Strings.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol";
import "@openzeppelin/contracts/utils/Address.sol";

import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";

import "../contracts/ROP.sol";
import "../contracts/Distribution.sol";

/// @title The pool's subsidiary contract for fundraising.
/// This contract collects funds, distributes them, and charges fees
/// @author Nethny
/// @dev This contract pulls commissions and other parameters from the Ranking contract.
/// Important: Agree on the structure of the ranking parameters and this contract!
/// Otherwise the calculations can be wrong!
contract BranchOfPools is Initializable {
    using Address for address;
    using Strings for uint256;

    enum State {
        Pause,
        Fundrasing,
        WaitingToken,
        TokenDistribution,
        Emergency
    }
    State public _state = State.Pause;

    address public _owner;
    address private _root;

    uint256 public _stepValue;
    uint256 public _VALUE;
    uint256 private _decimals;
    uint256 public _preSend;

    uint256 public _CURRENT_VALUE;
    uint256 public _FUNDS_RAISED;
    uint256 public _CURRENT_COMMISSION;
    uint256 public _CURRENT_VALUE_TOKEN;
    uint256 public _DISTRIBUTED_TOKEN;
    uint256 public _TOKEN_COMMISSION;

    mapping(address => uint256) public _valueUSDList;
    mapping(address => uint256) public _usdEmergency;
    mapping(address => uint256) public _issuedTokens;
    mapping(address => bool) public _withoutCommission;

    address[] public _listParticipants;

    address public _usd;
    address public _token;
    address public _devUSDAddress;

    struct Member {
        address awardsAddress;
        uint256 amount;
    }
    address public _distributor;
    mapping(string => Member) _team;
    string[] public _teamToken;
    string[] public _teamUSD;
    uint256 public _teamShare; //How much money does the team need in tokens
    uint256 public _currentTeamShare;

    uint256 public _unlockTime;

    uint256 public _refferalVolume;

    mapping(address => uint256) public _refferals;

    modifier onlyOwner() {
        require(msg.sender == _owner, "Ownable: Only owner");
        _;
    }

    function transferOwnership(address newOwner) public virtual onlyOwner {
        require(
            newOwner != address(0),
            "Ownable: new owner is the zero address"
        );
        _owner = newOwner;
    }

    /// @notice Assigns the necessary values to the variables
    /// @dev Just a constructor
    /// You need to call init()
    /// @param Root - RootOfPools contract address
    /// @param VALUE - The target amount of funds we collect
    /// @param Step - The step with which we raise funds
    /// @param devUSDAddress - The address of the developers to which they will receive the collected funds
    function init(
        address Root,
        uint256 VALUE,
        uint256 Step,
        address devUSDAddress,
        address tokenUSD,
        uint256 unlockTime
    ) external initializer {
        require(Root != address(0), "The root address must not be zero.");
        require(
            devUSDAddress != address(0),
            "The devUSDAddress must not be zero."
        );

        _owner = msg.sender;
        _root = Root;
        _usd = tokenUSD;
        _decimals = 10**ERC20(_usd).decimals();
        _VALUE = VALUE * _decimals;
        _stepValue = Step * _decimals;
        _devUSDAddress = devUSDAddress;
        _unlockTime = unlockTime;

        _distributor = RootOfPools_v2(_root)._distributor();
        string[] memory team = Distribution(_distributor).getTeam();
        for (uint256 i = 0; i < team.length; i++) {
            Distribution.TeamMember memory member = Distribution(_distributor)
                .getTeamMember(team[i]);

            _team[team[i]].amount = (_VALUE * member.interest) / member.shift;
            _team[team[i]].awardsAddress = member.addresses[
                member.awardsAddress
            ];

            if (member.choice) {
                //Receiving an award in tokens
                _teamToken.push(team[i]);
                _teamShare += _team[team[i]].amount;
            } else {
                //Receiving an award in usd
                _teamUSD.push(team[i]);
            }

            _valueUSDList[_team[team[i]].awardsAddress] = _team[team[i]].amount;
        }
    }

    function fillTeamShare(uint256 amount) public onlyState(State.Fundrasing) {
        require(_currentTeamShare + amount <= _teamShare);

        ERC20(_usd).transferFrom(tx.origin, address(this), amount);

        _currentTeamShare += amount;

        _CURRENT_VALUE += amount;
    }

    function getCommission() public {
        require(block.timestamp >= _unlockTime);
        if (_refferals[tx.origin] > 0) {
            uint256 amount = _refferals[tx.origin];

            _refferals[tx.origin] = 0;

            ERC20(_usd).transfer(tx.origin, amount);

            return;
        }

        for (uint256 i = 0; i < _teamUSD.length; i++) {
            if (tx.origin == _team[_teamUSD[i]].awardsAddress) {
                uint256 amount = _team[_teamUSD[i]].amount;

                _team[_teamUSD[i]].amount = 0;

                ERC20(_usd).transfer(tx.origin, amount);

                return;
            }
        }
    }

    /// @notice Changes the target amount of funds we collect
    /// @param value - the new target amount of funds raised
    function changeTargetValue(uint256 value)
        external
        onlyOwner
        onlyNotState(State.TokenDistribution)
        onlyNotState(State.WaitingToken)
    {
        _VALUE = value;

        _teamShare = 0;

        for (uint256 i = 0; i < _teamToken.length; i++) {
            Distribution.TeamMember memory member = Distribution(_distributor)
                .getTeamMember(_teamToken[i]);
            _team[_teamToken[i]].amount =
                (_VALUE * member.interest) /
                member.shift;

            _teamShare += _team[_teamToken[i]].amount;
        }

        for (uint256 i = 0; i < _teamUSD.length; i++) {
            Distribution.TeamMember memory member = Distribution(_distributor)
                .getTeamMember(_teamUSD[i]);
            _team[_teamUSD[i]].amount =
                (_VALUE * member.interest) /
                member.shift;
        }
    }

    /// @notice Changes the step with which we raise funds
    /// @param step - the new step
    function changeStepValue(uint256 step)
        external
        onlyOwner
        onlyNotState(State.TokenDistribution)
        onlyNotState(State.WaitingToken)
    {
        _stepValue = step;
    }

    modifier onlyState(State state) {
        require(_state == state, "STATE: It's impossible to do it now.");
        _;
    }

    modifier onlyNotState(State state) {
        require(_state != state, "STATE: It's impossible to do it now.");
        _;
    }

    /// @notice Opens fundraising
    function startFundraising() external onlyOwner onlyState(State.Pause) {
        _state = State.Fundrasing;
    }

    /// @notice Termination of fundraising and opening the possibility of refunds to depositors
    function stopEmergency()
        external
        onlyOwner
        onlyNotState(State.Pause)
        onlyNotState(State.TokenDistribution)
    {
        if (_state == State.WaitingToken) {
            uint256 balance = ERC20(_usd).balanceOf(address(this));
            require(
                balance >= _FUNDS_RAISED + _CURRENT_COMMISSION,
                "It takes money to get a refund"
            );
        }

        _state = State.Emergency;
    }

    /// @notice Returns the deposited funds to the caller
    /// @dev This is a bad way to write a transaction check,
    /// but in this case we are forced not to use require because of the usdt token implementation,
    /// which does not return a result. And to keep flexibility in terms of using different ERC20,
    /// we have to do it :\
    function paybackEmergency() external onlyState(State.Emergency) {
        uint256 usdT = _usdEmergency[tx.origin];

        if (usdT == 0) {
            revert("You have no funds to withdraw!");
        }

        _usdEmergency[tx.origin] = 0;

        ERC20(_usd).transfer(tx.origin, usdT);
    }

    /// @notice The function of the deposit of funds.
    /// @dev The contract attempts to debit the user's funds in the specified amount in the token whose contract is located at _usd
    /// the amount must be approved for THIS address
    /// @param amount - The number of funds the user wants to deposit
    function deposit(uint256 amount) external onlyState(State.Fundrasing) {
        uint256 commission;
        uint256[] memory rank = Ranking(RootOfPools_v2(_root)._rankingAddress())
            .getParRankOfUser(tx.origin);
        if (rank[2] != 0) {
            commission = (amount * rank[2]) / 100; //[Min, Max, Commission]
        }
        uint256 Min = _decimals * rank[0];
        uint256 Max = _decimals * rank[1];

        if (rank[2] == 0) {
            _withoutCommission[tx.origin] = true;
        }

        require(amount >= Min, "DEPOSIT: Too little funding!");
        require(
            amount + _valueUSDList[tx.origin] <= Max,
            "DEPOSIT: Too many funds!"
        );

        require((amount) % _stepValue == 0, "DEPOSIT: Must match the step!");
        require(
            _CURRENT_VALUE + amount - commission <= _VALUE - _teamShare,
            "DEPOSIT: Fundraising goal exceeded!"
        );

        ERC20(_usd).transferFrom(tx.origin, address(this), amount);
        _usdEmergency[tx.origin] += amount;

        if (_valueUSDList[tx.origin] == 0) {
            _listParticipants.push(tx.origin);
        }

        _valueUSDList[tx.origin] += amount - commission;
        _CURRENT_COMMISSION += commission;
        _CURRENT_VALUE += amount - commission;

        if (_CURRENT_VALUE == _VALUE) {
            _state = State.WaitingToken;
        }

        //Referral part
        Distribution.Member memory member = Distribution(_distributor)
            .getMember(tx.origin);
        if (member.owner != address(0)) {
            Distribution.ReferralOwner memory ownerMember = Distribution(
                _distributor
            ).getOwnerMember(member.owner);

            uint256 forDistribution = (amount * member.interest) / member.shift;

            _refferals[
                ownerMember.addresses[ownerMember.awardsAddress]
            ] += forDistribution;

            _refferalVolume += forDistribution;
        }
    }

    function preSend(uint256 amount)
        external
        onlyOwner
        onlyNotState(State.Pause)
        onlyNotState(State.TokenDistribution)
        onlyNotState(State.Emergency)
    {
        require(amount < _CURRENT_VALUE - _preSend);

        if (_state == State.WaitingToken) {
            uint256 balance = ERC20(_usd).balanceOf(address(this));
            require(balance == _CURRENT_VALUE - _preSend);
        }

        _preSend += amount;

        ERC20(_usd).transfer(_devUSDAddress, amount);
    }

    /// @notice Closes the fundraiser and distributes the funds raised
    /// Allows you to close the fundraiser before the fundraising amount is reached
    function stopFundraising()
        external
        onlyOwner
        onlyNotState(State.Pause)
        onlyNotState(State.TokenDistribution)
        onlyNotState(State.Emergency)
    {
        require(
            _CURRENT_VALUE == _VALUE,
            "COLLECT: The funds have already been withdrawn."
        );

        _FUNDS_RAISED = _CURRENT_VALUE;
        _CURRENT_VALUE = 0;

        //Send to devs
        ERC20(_usd).transfer(_devUSDAddress, _FUNDS_RAISED - _preSend);

        uint256 forTeam;
        for (uint256 i = 0; i < _teamUSD.length; i++) {
            forTeam += _team[_teamUSD[i]].amount;
        }

        //Send to admin
        ERC20(_usd).transfer(
            RootOfPools_v2(_root).owner(),
            ERC20(_usd).balanceOf(address(this)) - _refferalVolume - forTeam
        );
    }

    /// @notice Allows developers to transfer tokens for distribution to contributors
    /// @dev This function is only called from the developers address _devInteractionAddress
    /// @param tokenAddr - Developer token address
    function entrustToken(address tokenAddr)
        external
        onlyOwner
        onlyNotState(State.Emergency)
        onlyNotState(State.Fundrasing)
        onlyNotState(State.Pause)
    {
        require(
            tokenAddr != address(0),
            "ENTRUST: The tokenAddr must not be zero."
        );

        _token = tokenAddr;

        _state = State.TokenDistribution;
    }

    //TODO
    /// @notice Allows users to brand the distributed tokens
    function claim() external onlyState(State.TokenDistribution) {
        require(
            _valueUSDList[tx.origin] > 0,
            "CLAIM: You have no unredeemed tokens!"
        );

        uint256 amount;

        uint256 currentTokenBalance = ERC20(_token).balanceOf(address(this));

        if (_CURRENT_VALUE_TOKEN < currentTokenBalance) {
            uint256 temp = currentTokenBalance - _CURRENT_VALUE_TOKEN;
            _CURRENT_VALUE_TOKEN += temp;
        }

        amount =
            (
                ((_valueUSDList[tx.origin] *
                    (_CURRENT_VALUE_TOKEN + _DISTRIBUTED_TOKEN)) /
                    _FUNDS_RAISED)
            ) -
            _issuedTokens[tx.origin];

        _issuedTokens[tx.origin] += amount;
        _DISTRIBUTED_TOKEN += amount;
        _CURRENT_VALUE_TOKEN -= amount;

        if (amount > 0) {
            ERC20(_token).transfer(tx.origin, amount);
        }
    }

    /// @notice Returns the amount of funds that the user deposited
    /// @param user - address user
    function myAllocationEmergency(address user)
        external
        view
        returns (uint256)
    {
        return _usdEmergency[user];
    }

    /// @notice Returns the number of tokens the user can take at the moment
    /// @param user - address user
    function myCurrentAllocation(address user) public view returns (uint256) {
        if (_FUNDS_RAISED == 0) {
            return 0;
        }

        uint256 amount = (
            ((_valueUSDList[user] *
                (_CURRENT_VALUE_TOKEN + _DISTRIBUTED_TOKEN)) / _FUNDS_RAISED)
        ) - _issuedTokens[user];

        return amount;
    }

    /// @notice Auxiliary function for RootOfPools claimAll
    /// @param user - address user
    function isClaimable(address user) external view returns (bool) {
        return myCurrentAllocation(user) > 0;
    }
}
