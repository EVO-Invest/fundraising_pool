// SPDX-License-Identifier: Unknown

pragma solidity ^0.8.7;

import "../FundCoreLib.sol";

contract FundCoreLibImpl {
    using FundCoreLib for FundCoreLib.FundMath;

    event TokensClaimed(uint256 amount);

    FundCoreLib.FundMath math;

    constructor(uint256 goal) {
        math.changeFundraisingGoal(goal);
    }

    function onDepositInputTokens(address sender, uint256 amount, uint256 fees) public {
        math.onDepositInputTokens(sender, amount, fees);
    }

    function ownersShare() view public returns (uint256) {
        return math.ownersShare();
    }

    function requiredAmountToCloseFundraising() view public returns (uint256) {
        return math.requiredAmountToCloseFundraising();
    }

    function claimOutputTokens(address receiver, uint256 outputTokenSupply) public {
        uint256 amount = math.claimOutputTokens(receiver, outputTokenSupply);
        emit TokensClaimed(amount);
    }

    function closeFundraising(uint256 extraFunds, address admin) public {
        math.closeFundraising(extraFunds, admin);
    }

    function changeFundraisingGoal(uint256 newFundraisingTarget) public {
        math.changeFundraisingGoal(newFundraisingTarget);
    }

    function updateOutputTokenSalary(address receiver, uint256 oldAmount, uint256 newAmount) public {
        math.updateOutputTokenSalary(receiver, oldAmount, newAmount);
    }

    function updateInputTokenSalary(address receiver, uint256 oldAmount, uint256 newAmount) public {
        math.updateInputTokenSalary(receiver, oldAmount, newAmount);
    }
}