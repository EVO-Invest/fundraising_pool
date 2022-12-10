//SPDX-License-Identifier: GNU GPLv3
pragma solidity ^0.8.2;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/utils/Strings.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol";
import "@openzeppelin/contracts/utils/Address.sol";

import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";

import "../contracts/ROP.sol";
import "../contracts/RewardDistributor.sol";
import "../contracts/UnionWallet.sol";
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

    FundCoreLib.FundMath math;

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
    uint256 public _VALUE;
    uint256 private _decimals;
    uint256 public _preSend;

    // _VALUE - is the amount of USD we are planning to collect.
    // _CURRENT_VALUE - is the amount of USD we are ready to send right now.
    //     _CURRENT_VALUE = sum(deposits) 
    //                      - sum(commissions_for_owners_and_usd_team)
    //                      + sum(commissions_for_token_team).
    // _TOTAL_COMMISSIONS - is the total amount of money we need to subtract.
    //     The trick here is that sum(commissions_for_owners_and_usd_team) +
    //     sum(commissions_for_token_team) could be higher than the amount of
    //     already collected comissions. We should not allow to close the pool
    //     when we are in dept.
    uint256 public _CURRENT_VALUE;
    uint256 public _FUNDS_RAISED;
    uint256 public _DISTRIBUTED_TOKEN;

    mapping(address => uint256) public _valueUSDList;

    /* _usdEmergency stores the original amount of funds deposited,
       no comissions, no nothing. So that in case of emergency,
       users can get exactly what they paid. */
    mapping(address => uint256) public _usdEmergency;
    mapping(address => uint256) public _issuedTokens;

    ERC20 public _usd;
    ERC20 public _token;
    address public _devUSDAddress;

    struct Member {
        address awardsAddress;
        uint256 amount;
    }

    uint256 public _unlockTime;

    RewardDistributor _distributor;
    mapping(address => uint256) _postCloseUsdDistribution;
    mapping(address => uint256) _postGotTokensUsdDistribution;

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

         math.changeFundraisingGoal(VALUE);

        __Ownable_init();

        _distributor = RewardDistributor(RootOfPools_v2(_root)._distributor());
        _unionWallet = UnionWallet(RootOfPools_v2(_root)._unionWallet());

        _distributor.createTeamSnapshot();
    }

    function getCommission() public {
        address user = _unionWallet.resolveIdentity(msg.sender);
        uint256 amountToTransfer = 0;
        if (stateSameOrAfter(State.WaitingToken)) {
            if (_postCloseUsdDistribution[user] > 0) {
                amountToTransfer += _postCloseUsdDistribution[user];
                _postCloseUsdDistribution[user] = 0;
            }
        }
        if (stateSameOrAfter(State.TokenDistribution) || (block.timestamp >= _unlockTime)) {
            if (_postGotTokensUsdDistribution[user] > 0) {
                amountToTransfer += _postGotTokensUsdDistribution[user];
                _postGotTokensUsdDistribution[user] = 0;
            }
        }
        require(amountToTransfer > 0, "No comissions to collect");
        _usd.transfer(
            msg.sender, /* Important: getting amount from identity, but sending to msg.sender */
            amountToTransfer
        );
    }

    /// @notice Changes the target amount of funds we collect
    /// @param newFundraisingTarget - the new target amount of funds raised
    function changeFundraisingGoal(uint256 newFundraisingTarget) 
        public
        onlyOwner
    {
        math.changeFundraisingGoal(newFundraisingTarget);
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
        address user = _unionWallet.resolveIdentity(msg.sender);
        uint256 usdT = _usdEmergency[user];
        require(usdT > 0, "You have no funds to withdraw!");
        _usdEmergency[user] = 0;
        _usd.transfer(msg.sender, usdT);
    }

    /// @notice The function of the deposit of funds.
    /// @dev The contract attempts to debit the user's funds in the specified amount in the token whose contract is located at _usd
    /// the amount must be approved for THIS address
    /// @param amount - The number of funds the user wants to deposit
    function deposit(uint256 amount) external stateCheck(State.Fundraising, true) {
        address user = _unionWallet.resolveIdentity(msg.sender);
        uint256[] memory rank = Ranking(RootOfPools_v2(_root)._rankingAddress())
            .getParRankOfUser(user);
        uint256 Min = _decimals * rank[0];
        uint256 Max = _decimals * rank[1];

        require(amount >= Min && 
                amount + _valueUSDList[user] <= Max &&
                amount % _stepValue == 0,
                "DEPOSIT: Wrong funding!");

        uint256 commission = 0;
        uint256 heldUsd = 0;
        (RewardDistributor.ComissionPlacement[] memory placements, address[] memory addresses, uint256[] memory amounts) =
            _distributor.calculateComissions(user, amount);
        for (uint256 rewardAcceptorIndex = 0; rewardAcceptorIndex < placements.length; ++rewardAcceptorIndex) {
            address rewardAddress = addresses[rewardAcceptorIndex];
            uint256 rewardAmount = amounts[rewardAcceptorIndex];
            commission += rewardAmount;
            if (placements[rewardAcceptorIndex] == RewardDistributor.ComissionPlacement.STABLE_POST_FUND_CLOSE) {
                heldUsd += rewardAmount;
                _postCloseUsdDistribution[rewardAddress] += rewardAmount;
            } else if (placements[rewardAcceptorIndex] == RewardDistributor.ComissionPlacement.STABLE_POST_DISTRIBUTION) {
                heldUsd += rewardAmount;
                _postGotTokensUsdDistribution[rewardAddress] += rewardAmount;
            } else if (placements[rewardAcceptorIndex] == RewardDistributor.ComissionPlacement.TOKEN) {
                /* commission here is not added, as the commission is showing how much money we are holding
                   back, and not sending to the project. When distributor decided to distribute token
                   to someone, USD are still going to the fund. We are just saying that the reward acceptor
                   will get tokens equal to as he paid themselfes.
                */
                _valueUSDList[rewardAddress] += rewardAmount;
            }
        }
        _CURRENT_VALUE += amount - heldUsd;
        require(_CURRENT_VALUE <= _VALUE, "DEPOSIT: Fundraising goal exceeded!");

        _usdEmergency[user] += amount;
        _valueUSDList[user] += amount - commission;

        if (_CURRENT_VALUE == _VALUE) {
            _state = State.WaitingToken;
        }
    }

    function preSend(uint256 amount)
        external
        onlyOwner
        stateCheck(State.Paused, false)
        stateCheck(State.TokenDistribution, false)
        stateCheck(State.Emergency, false)
    {
        require(amount < _CURRENT_VALUE - _preSend);

        if (_state == State.WaitingToken) {
            uint256 balance = _usd.balanceOf(address(this));
            require(balance == _CURRENT_VALUE - _preSend);
        }

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
        require(
            _CURRENT_VALUE == _VALUE,
            "COLLECT: The funds have already been withdrawn."
        );

        _FUNDS_RAISED = _CURRENT_VALUE;
        _CURRENT_VALUE = 0;

        //Send to devs
        _usd.transfer(_devUSDAddress, _FUNDS_RAISED - _preSend);
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
        uint256 amount = myCurrentAllocation(user);
        _issuedTokens[user] += amount;
        _DISTRIBUTED_TOKEN += amount;
        require(amount > 0, "CLAIM: You have no unredeemed tokens!");
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
        if (_FUNDS_RAISED == 0) {
            return 0;
        }

        user = _unionWallet.resolveIdentity(user);
        uint256 currentTokenBalance = _token.balanceOf(address(this));
        uint256 amount = (
            ((_valueUSDList[user] *
                (currentTokenBalance + _DISTRIBUTED_TOKEN)) / _FUNDS_RAISED)
        ) - _issuedTokens[user];

        return amount;
    }

    /// @notice Auxiliary function for RootOfPools claimAll
    /// @param user - address user
    function isClaimable(address user) external view returns (bool) {
        return myCurrentAllocation(user) > 0;
    }
}
