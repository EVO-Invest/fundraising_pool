// SPDX-License-Identifier: Unknown

pragma solidity ^0.8.7;


// This library implements basic fundraising logic with respect to fee
// distribution but nothing more than this. All of the checks etc
// are up to the caller.

// This is done to make unit testing possible because testing the whole
// BOP + ROP + Rankings is very difficult.

// Use it carefully, it is fully trustful and has no protection.
// Purely extracted only for math computations.

library FundCoreLib {
    struct FundMath {
        // Amount of input tokens we agreed to send to the project.
        uint256 fundraisingTarget;

        mapping(address => uint256) participation;

        // All incoming tokens are counted as `collected` tokens.
        uint256 collected;

        // Some of the collected money are used to pay salaries in input tokens.
        mapping(address => uint256) salaries;
        uint256 totalInputTokenSalaries;

        uint256 allocationsGiven;
        mapping(address => uint256) claimedOutputTokens;
        
        // At the moment when the fundraising closed, we should have
        // collected >= fundraisingTarget + totalInputTokenSalaries
        // allocationsGiven == fundraisingTarget
    }

    function onDepositInputTokens(FundMath storage data, address sender, uint256 amount, uint256 fees) internal {
        data.participation[sender] += amount;
        data.collected += amount + fees;
        data.allocationsGiven += amount;
        require(data.allocationsGiven <= data.fundraisingTarget, "Overallocated");
    }

    function requiredAmountToCloseFundraising(FundMath storage data) view internal returns (uint256) {
        if (data.collected >= data.fundraisingTarget + data.totalInputTokenSalaries) return 0;
        return data.fundraisingTarget + data.totalInputTokenSalaries - data.collected;
    }

    function ownersShare(FundMath storage data) view internal returns (uint256) {
        if (data.collected >= data.fundraisingTarget + data.totalInputTokenSalaries)
            return data.collected - data.fundraisingTarget - data.totalInputTokenSalaries;
        return 0;
    }

    function closeFundraising(FundMath storage data, uint256 extraFunds, address admin) internal {
        data.collected += extraFunds;
        data.participation[admin] += data.fundraisingTarget - data.allocationsGiven;
        data.allocationsGiven = data.fundraisingTarget;
        require(requiredAmountToCloseFundraising(data) == 0, "Can't stop funraising");
    }

    function myOutputTokens(FundMath storage data, address receiver, uint256 outputTokenSupply) internal view returns (uint256) {
        return outputTokenSupply * data.participation[receiver] / data.fundraisingTarget - data.claimedOutputTokens[receiver];
    }
    function claimOutputTokens(FundMath storage data, address receiver, uint256 outputTokenSupply) internal returns (uint256) {
        uint256 myShare = outputTokenSupply * data.participation[receiver] / data.fundraisingTarget - data.claimedOutputTokens[receiver];
        data.claimedOutputTokens[receiver] += myShare;
        return myShare;
    }

    // update...Salary methods MUST be called before changeFundraisingGoal.
    function changeFundraisingGoal(FundMath storage data, uint256 newFundraisingTarget) internal {
        require(newFundraisingTarget >= data.allocationsGiven, "Can't shrink existing allocations");
        data.fundraisingTarget = newFundraisingTarget;
    }

    // update...Salary methods MUST be called before changeFundraisingGoal.
    function updateOutputTokenSalary(FundMath storage data, address receiver, uint256 oldAmount, uint256 newAmount) internal {
        data.participation[receiver] += newAmount;
        data.participation[receiver] -= oldAmount;
        data.allocationsGiven += newAmount;
        data.allocationsGiven -= oldAmount;
    }
    function updateInputTokenSalary(FundMath storage data, address receiver, uint256 oldAmount, uint256 newAmount) internal {
        data.salaries[receiver] += newAmount;
        data.salaries[receiver] -= oldAmount;
        data.totalInputTokenSalaries += newAmount;
        data.totalInputTokenSalaries -= oldAmount;
    }

    function takeSalary(FundMath storage data, address receiver) internal returns (uint256 salaryAmount) {
        salaryAmount = data.salaries[receiver];
        data.salaries[receiver] = 0;
        data.totalInputTokenSalaries -= salaryAmount;
    }

    function getFundraisingTarget(FundMath storage data) internal view returns (uint256) {
        return data.fundraisingTarget;
    }

    function getTotalCollected(FundMath storage data) internal view returns (uint256) {
        return data.collected;
    }
}