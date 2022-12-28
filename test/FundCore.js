const { expect } = require("chai");
const { ethers } = require("hardhat");

const chai = require('chai');
chai.use(require('chai-bignumber')());

describe("FundCore", () => {
    beforeEach(async () => {
        const FundCoreLibImpl = await ethers.getContractFactory("FundCoreLibImpl");
        this.fundCore = await FundCoreLibImpl.deploy("1000000");
        const [admin, alice, bob, charlie] = await ethers.getSigners();
        this.admin = admin;
        this.alice = alice;
        this.bob = bob;
        this.charlie = charlie;
    })

    describe("No team", () => {
        it("Owner receives all funds", async () => {
            for (let i = 0; i < 10; ++i) {
                await this.fundCore.onDepositInputTokens(this.admin.address, "100000", "15000");
            }
            expect(await this.fundCore.ownersShare()).to.be.bignumber.equal("150000");
        });

        it("We are protected from overflows", async () => {
            for (let i = 0; i < 9; ++i) {
                await this.fundCore.onDepositInputTokens(this.admin.address, "100000", "15000");
            }
            await expect(this.fundCore.onDepositInputTokens(this.admin.address, "100001", "15000")).to.be.reverted;
        });

        it("Even if we don't have enough funds, we can close the funraising", async () => {
            for (let i = 0; i < 9; ++i) {
                await this.fundCore.onDepositInputTokens(this.alice.address, "100000", "15000");
            }
            // Collected 900'000 and 135'000 fees. So...
            expect(await this.fundCore.ownersShare()).to.be.bignumber.equal("35000");
            expect(await this.fundCore.requiredAmountToCloseFundraising()).to.be.bignumber.equal("0");
            await this.fundCore.closeFundraising(0, this.admin.address);
            const tx = await this.fundCore.claimOutputTokens(this.admin.address, 1000);
            const effects = await tx.wait();
            expect(effects.events[0].args[0]).to.be.bignumber.equal("100");
            // Claiming once again should give no effect
            const tx2 = await this.fundCore.claimOutputTokens(this.admin.address, 1000);
            const effects2 = await tx2.wait();
            expect(effects2.events[0].args[0]).to.be.bignumber.equal("0");
            // But on the next unlock it should
            const tx3 = await this.fundCore.claimOutputTokens(this.admin.address, 10000);
            const effects3 = await tx3.wait();
            expect(effects3.events[0].args[0]).to.be.bignumber.equal("900");
            const tx4 = await this.fundCore.claimOutputTokens(this.alice.address, 10000);
            const effects4 = await tx4.wait();
            expect(effects4.events[0].args[0]).to.be.bignumber.equal("9000");
        });

        it("When we are significantly underfunded we have to pay", async () => {
            await this.fundCore.onDepositInputTokens(this.alice.address, "500000", "100000");
            expect(await this.fundCore.ownersShare()).to.be.bignumber.equal("0");
            expect(await this.fundCore.requiredAmountToCloseFundraising()).to.be.bignumber.equal("400000");
            await expect(this.fundCore.closeFundraising(399999, this.admin.address)).to.be.reverted;
            await this.fundCore.closeFundraising(400000, this.admin.address);
        });

        it("When we are significantly underfunded we can change target", async () => {
            await this.fundCore.onDepositInputTokens(this.alice.address, "500000", "100000");

            expect(await this.fundCore.ownersShare()).to.be.bignumber.equal("0");
            expect(await this.fundCore.requiredAmountToCloseFundraising()).to.be.bignumber.equal("400000");
            
            await this.fundCore.changeFundraisingGoal("550000");
            expect(await this.fundCore.ownersShare()).to.be.bignumber.equal("50000");
            expect(await this.fundCore.requiredAmountToCloseFundraising()).to.be.bignumber.equal("0");

            await this.fundCore.changeFundraisingGoal("500000");
            await expect(this.fundCore.changeFundraisingGoal("499999")).to.be.reverted;
        });
    });

    describe("Team work", async () => {
        beforeEach(async () => {
            await this.fundCore.updateInputTokenSalary(this.bob.address, "0", "10000");
            await this.fundCore.updateOutputTokenSalary(this.charlie.address, "0", "10000");
        });

        const sendAsMuchAsPossible = async (commission) => {
            let amount = 1000000;
            let total = 0, totalFee = 0;
            while (amount >= 1) {
                try {
                    await this.fundCore.onDepositInputTokens(this.alice.address, Math.round(amount), Math.round(amount * commission));
                    total += Math.round(amount);
                    totalFee += Math.round(amount * 0.15);
                }
                catch (e) {
                    amount = Math.floor(amount / 2);
                }
            }
            return [total, totalFee];
        };

        it("Makes sense", async () => {
            const [totalPaid, totalFees] = await sendAsMuchAsPossible(0.15);

            // 1. Owner should not pay anything.
            expect(await this.fundCore.ownersShare()).to.be.bignumber.equal("128500");
            expect(await this.fundCore.requiredAmountToCloseFundraising()).to.be.bignumber.equal("0");
            await this.fundCore.closeFundraising(0, this.admin.address);

            // 2. Sender paid 990'000 + 148'500 and can take 990 coins.
            // console.log(totalPaid, totalFees)
            const tx = await this.fundCore.claimOutputTokens(this.alice.address, 1000);
            const effects = await tx.wait();
            expect(effects.events[0].args[0]).to.be.bignumber.equal("990");
            
            // 3. Charlie can receive 10 coins, and no one else could.
            const tx2 = await this.fundCore.claimOutputTokens(this.charlie.address, 1000);
            const effects2 = await tx2.wait();
            expect(effects2.events[0].args[0]).to.be.bignumber.equal("10");
            const tx4 = await this.fundCore.claimOutputTokens(this.bob.address, 1000);
            const effects4 = await tx4.wait();
            expect(effects4.events[0].args[0]).to.be.bignumber.equal("0");
        });

        it("Case with 0 commissions", async () => {
            const [totalPaid, totalFees] = await sendAsMuchAsPossible(0);

            // 1. Owner should pay salaries.
            expect(await this.fundCore.ownersShare()).to.be.bignumber.equal("0");
            expect(await this.fundCore.requiredAmountToCloseFundraising()).to.be.bignumber.equal("20000");
            await expect(this.fundCore.closeFundraising(19999, this.admin.address)).to.be.reverted;
            await this.fundCore.closeFundraising(20000, this.admin.address);

            // 2. Sender paid 990'000 and can take 990 coins.
            // console.log(totalPaid, totalFees)
            const tx = await this.fundCore.claimOutputTokens(this.alice.address, 1000);
            const effects = await tx.wait();
            expect(effects.events[0].args[0]).to.be.bignumber.equal("990");
            
            // 3. Charlie can receive 10 coins, and no one else could.
            const tx2 = await this.fundCore.claimOutputTokens(this.charlie.address, 1000);
            const effects2 = await tx2.wait();
            expect(effects2.events[0].args[0]).to.be.bignumber.equal("10");
            const tx3 = await this.fundCore.claimOutputTokens(this.admin.address, 1000);
            const effects3 = await tx3.wait();
            expect(effects3.events[0].args[0]).to.be.bignumber.equal("0");
            const tx4 = await this.fundCore.claimOutputTokens(this.bob.address, 1000);
            const effects4 = await tx4.wait();
            expect(effects4.events[0].args[0]).to.be.bignumber.equal("0");
        });
    });
});