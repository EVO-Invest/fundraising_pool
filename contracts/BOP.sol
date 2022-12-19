//SPDX-License-Identifier: GNU GPLv3
pragma solidity ^0.8.2;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/utils/Strings.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol";
import "@openzeppelin/contracts/utils/Address.sol";

import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";

import "./ROP.sol";
import "./RewardCalcs.sol";
import "./UnionWallet.sol";
import "./FundCoreLib.sol";

/// @title The pool's subsidiary contract for fundraising.
/// This contract collects funds, distributes them, and charges fees
/// @author Nethny
/// @dev This contract pulls commissions and other parameters from the Ranking contract.
/// Important: Agree on the structure of the ranking parameters and this contract!
/// Otherwise the calculations can be wrong!
contract BranchOfPools is Initializable, OwnableUpgradeable {
    using Address for address;
    using Strings for uint256;
    using FundCoreLib for FundCoreLib.FundMath;

    enum State {
        Paused,
        Fundraising,
        WaitingToken,
        TokenDistribution,
        Emergency
    }
    
    State public _state;

    address private _root;

    uint256 public _stepValue;
    uint256 private _decimals;

    // Amount of USD we send in a test transaction.
    uint256 public _preSend;

    // Total amount of token we already distributed.
    // So that token.balanceOf(this) + _DISTRIBUTED_TOKEN = amount of received token.
    uint256 public _DISTRIBUTED_TOKEN;
    bool _ownerAlreadyCollectedFunds;

    /* _usdEmergency stores the original amount of funds deposited,
       no commissions, no nothing. So that in case of emergency,
       users can get exactly what they paid. */
    mapping(address => uint256) public _usdEmergency;

    uint256 _teamSnapshotId;

    ERC20 public _usd;
    ERC20 public _token;
    address public _devUSDAddress;
    uint256 public _unlockTime;
    uint256 _defaultCommission;

    FundCoreLib.FundMath _fundMath;
    RewardCalcs _rewardCalcs;
    UnionWallet _unionWallet;

    // choice = true | onlyState modifier
    // choice = false | onlyNotState modifier
    modifier stateCheck(State state, bool choice) {
        require(choice ? _state == state : _state != state, "BOP: State error!");
        _;
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

        _state = State.Paused;
        _root = Root;
        _usd = ERC20(tokenUSD);
        _decimals = 10**_usd.decimals();
        _stepValue = Step * _decimals;
        _devUSDAddress = devUSDAddress;
        _unlockTime = unlockTime;
        _ownerAlreadyCollectedFunds = false;

        __Ownable_init();

        _rewardCalcs = RewardCalcs(RootOfPools_v2(_root)._rewardCalcs());
        _unionWallet = UnionWallet(RootOfPools_v2(_root)._unionWallet());

        _teamSnapshotId = _rewardCalcs.snapshotTeam();
        updateFundraisingTarget(VALUE * _decimals);

        _defaultCommission = Ranking(RootOfPools_v2(_root)._rankingAddress())
            .getParRankOfUser(address(0x0))[2];
    }

    function updateFundraisingTarget(uint256 fundraisingTarget) internal {
        uint256 previousTarget = _fundMath.getFundraisingTarget();
        for (uint256 i = 0; i < _rewardCalcs.allTeamLength(); ++i) {
            address memberAddress = _rewardCalcs.allTeamAt(i);
            (uint16 commission, RewardCalcs.TeamMemberRewardTypeChoice choice) = _rewardCalcs.teamMemberRewardInfoAt(memberAddress, _teamSnapshotId);
            uint256 prevSalaryExpectation = previousTarget * commission / _rewardCalcs._denominator();
            uint256 newSalaryExpectation = fundraisingTarget * commission / _rewardCalcs._denominator();
            if (choice == RewardCalcs.TeamMemberRewardTypeChoice.TOKEN) {
                _fundMath.updateOutputTokenSalary(memberAddress, prevSalaryExpectation, newSalaryExpectation);
            } else {
                _fundMath.updateInputTokenSalary(memberAddress, prevSalaryExpectation, newSalaryExpectation);
            }
        }
        _fundMath.changeFundraisingGoal(fundraisingTarget);
    }

    function getCommission() public {
        if (stateSameOrAfter(State.WaitingToken) && _ownerAlreadyCollectedFunds) {
            _ownerAlreadyCollectedFunds = false;
            _usd.transfer(
                owner(),
                _fundMath.ownersShare()
            );
        }

        if (stateSameOrAfter(State.TokenDistribution) || (block.timestamp >= _unlockTime)) {
            address user = _unionWallet.resolveIdentity(tx.origin);
            // Ref. payments are also treates as salary by our depositing code.
            _usd.transfer(
                tx.origin,
                _fundMath.takeSalary(user)
            );
        }
    }

    /// @notice Changes the target amount of funds we collect
    /// @param newFundraisingTarget - the new target amount of funds raised
    function changeFundraisingGoal(uint256 newFundraisingTarget) 
        public
        onlyOwner
    {
        require(stateSameOrBefore(State.Fundraising), "Too late to change value");
        updateFundraisingTarget(newFundraisingTarget * _decimals);
    }

    /// @notice Changes the step with which we raise funds
    /// @param step - the new step
    function changeStepValue(uint256 step)
        external
        onlyOwner
    {
        require(stateSameOrBefore(State.Fundraising), "Too late to change value");
        _stepValue = step;
    }

    /// @notice Opens fundraising
    function startFundraising() external onlyOwner stateCheck(State.Paused, true) {
        _state = State.Fundraising;
    }

    /// @notice Termination of fundraising and opening the possibility of refunds to depositors
    function stopEmergency()
        external
        onlyOwner
        stateCheck(State.Paused, false)
        stateCheck(State.TokenDistribution, false)
    {
        _state = State.Emergency;
    }

    /// @notice Returns the deposited funds to the caller
    /// @dev This is a bad way to write a transaction check,
    /// but in this case we are forced not to use require because of the usdt token implementation,
    /// which does not return a result. And to keep flexibility in terms of using different ERC20,
    /// we have to do it :\
    function paybackEmergency() external stateCheck(State.Emergency, true) {
        address user = _unionWallet.resolveIdentity(tx.origin);
        uint256 usdT = _usdEmergency[user];
        require(usdT > 0, "You have no funds to withdraw!");
        _usdEmergency[user] = 0;
        _usd.transfer(tx.origin, usdT);
    }

    /// @notice The function of the deposit of funds.
    /// @dev The contract attempts to debit the user's funds in the specified amount in the token whose contract is located at _usd
    /// the amount must be approved for THIS address
    /// @param amount - The number of funds the user wants to deposit
    function deposit(uint256 amount) external stateCheck(State.Fundraising, true) {
        _usd.transferFrom(tx.origin, address(this), amount);
        address user = _unionWallet.resolveIdentity(tx.origin);
        _usdEmergency[user] += amount;

        uint256[] memory rank = Ranking(RootOfPools_v2(_root)._rankingAddress())
            .getParRankOfUser(user);

        require(amount >= /* Min=*/ _decimals * rank[0] && 
                amount + _usdEmergency[user] <= /* Max=*/ _decimals * rank[1] &&
                amount % _stepValue == 0,
                "DEPOSIT: Wrong funding!");

        uint256 totalCommissions = amount * /* CommissionPrc=*/ rank[2] / 100;
        _fundMath.onDepositInputTokens(user, amount - totalCommissions, totalCommissions);
        (uint256 referralCommission, address referral) = _rewardCalcs.calculateReferralsCommission(user, amount, totalCommissions, amount * _defaultCommission / 100);
        _fundMath.updateInputTokenSalary(referral, 0, referralCommission);
    }

    function preSend(uint256 amount)
        external
        onlyOwner
        stateCheck(State.Paused, false)
        stateCheck(State.Emergency, false)
    {
        require(amount + _preSend <= _fundMath.getFundraisingTarget());
        _preSend += amount;
        _usd.transfer(_devUSDAddress, amount);
    }

    /// @notice Closes the fundraiser and distributes the funds raised
    /// Allows you to close the fundraiser before the fundraising amount is reached
    function stopFundraising()
        external
        onlyOwner
        stateCheck(State.Paused, false)
        stateCheck(State.TokenDistribution, false)
        stateCheck(State.Emergency, false)
    {
        _fundMath.closeFundraising(0, owner());
        _state = State.WaitingToken;
    }

    function requiredAmountToCloseFundraising() external view stateCheck(State.Fundraising, true) returns (uint256) {
        return _fundMath.requiredAmountToCloseFundraising();
    }

    /// @notice Allows developers to transfer tokens for distribution to contributors
    /// @dev This function is only called from the developers address _devInteractionAddress
    /// @param tokenAddr - Developer token address
    function entrustToken(address tokenAddr)
        external
        onlyOwner
        stateCheck(State.Emergency, false)
        stateCheck(State.Fundraising, false)
        stateCheck(State.Paused, false)
    {
        require(
            tokenAddr != address(0),
            "ENTRUST: The tokenAddr must not be zero."
        );

        _token = ERC20(tokenAddr);
        _state = State.TokenDistribution;
    }

    /// @notice Allows users to brand the distributed tokens
    function claim() external stateCheck(State.TokenDistribution, true) {
        address user = _unionWallet.resolveIdentity(msg.sender);
        uint256 amount = _fundMath.claimOutputTokens(user, _DISTRIBUTED_TOKEN + _token.balanceOf(address(this)));
        require(amount > 0, "CLAIM: You have no unredeemed tokens!");
        _DISTRIBUTED_TOKEN += amount;
        _token.transfer(msg.sender, amount);
    }

    function stateSameOrAfter(State s) public view returns (bool) {
        if (_state == s) return true;
        if (_state == State.Emergency) return false;
        if (s == State.Paused) return true;
        if (s == State.Fundraising) return (_state == State.WaitingToken || _state == State.TokenDistribution);
        if (s == State.WaitingToken) return (_state == State.TokenDistribution);
        return false;  // No states after TokenDistributon.
    }

    function stateSameOrBefore(State s) public view returns (bool) {
        if (_state == s) return true;
        if (_state == State.Emergency) return false;
        if (s == State.TokenDistribution) return true;
        if (s == State.WaitingToken) return (_state == State.Fundraising || _state == State.Paused);
        if (s == State.Fundraising) return (_state == State.Paused);
        return false;  // No states before Paused.
    }

    /// @notice Returns the amount of funds that the user deposited
    /// @param user - address user
    function myAllocationEmergency(address user)
        external
        view
        returns (uint256)
    {
        return _usdEmergency[_unionWallet.resolveIdentity(user)];
    }

    /// @notice Returns the number of tokens the user can take at the moment
    /// @param user - address user
    function myCurrentAllocation(address user) public view returns (uint256) {
        if (_state != State.TokenDistribution)
            return 0;
        return _fundMath.myOutputTokens(user, _DISTRIBUTED_TOKEN + _token.balanceOf(address(this)));
    }

    /// @notice Auxiliary function for RootOfPools claimAll
    /// @param user - address user
    function isClaimable(address user) external view returns (bool) {
        return myCurrentAllocation(user) > 0;
    }
}
