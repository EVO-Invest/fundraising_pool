const { expect } = require("chai");
const { ethers, upgrades } = require("hardhat");

const chai = require('chai');
chai.use(require('chai-bignumber')());

describe("RewardCalcs", () => {
    beforeEach(async () => {
        const [admin, alice, bob, charlie] = await ethers.getSigners();
        this.admin = admin;
        this.alice = alice;
        this.bob = bob;
        this.charlie = charlie;

        const UnionWallet = await ethers.getContractFactory("UnionWallet");
        this.unionwallet = await UnionWallet.deploy();

        const RewardCalcs = await ethers.getContractFactory("RewardCalcs");
        this.rewardCalcs = await upgrades.deployProxy(RewardCalcs, [this.admin.address, this.admin.address, this.unionwallet.address]);

        this.checkSnap = async (who, when, expectedCommission, expectedPaymentType) => { 
            const [commission, paymentType] = await this.rewardCalcs.teamMemberRewardInfoAt(who, when);
            expect(commission).to.be.equal(expectedCommission);
            expect(paymentType).to.be.equal(expectedPaymentType);
        }

        this.checkCommission = async (user, deposit, commission, expectedRefReward) => {
            const defaultCommission = deposit * 15 / 100;
            const refReward = await this.rewardCalcs.calculateReferralsCommission(user, deposit, commission, defaultCommission);
            expect(refReward).to.be.equal(expectedRefReward);
        }
    })

    it("Check snapshotting", async () => {
        await this.rewardCalcs.addTeamMember(this.alice.address, 50, 1);
        await this.rewardCalcs.snapshotTeam();
        // ^^ snapshot 1: alice, commission 50, stable

        await this.rewardCalcs.updateTeamMember(this.alice.address, 100);
        await this.rewardCalcs.connect(this.alice).updateMyRewardTypeChoice(0);
        await this.rewardCalcs.addTeamMember(this.bob.address, 50, 0);
        await this.rewardCalcs.snapshotTeam();
        // ^^ snapshot 2: alice, commission 100, token
        //                bob,   commission 50,  token

        await this.rewardCalcs.updateTeamMember(this.alice.address, 200);
        await this.rewardCalcs.updateTeamMember(this.bob.address, 200);
        await this.rewardCalcs.connect(this.alice).updateMyRewardTypeChoice(0);
        await this.rewardCalcs.connect(this.bob).updateMyRewardTypeChoice(1);
        // ^^ mode not snapshotted changes

        let snapId = 1;
        await this.checkSnap(this.alice.address, snapId, 50, 1)
        await this.checkSnap(this.bob.address,   snapId, 0, 1)

        snapId = 2;
        await this.checkSnap(this.alice.address, snapId, 100, 0)
        await this.checkSnap(this.bob.address,   snapId, 50, 0)

        expect(await this.rewardCalcs.allTeamLength()).to.be.equal(2)
        expect(await this.rewardCalcs.allTeamAt(0)).to.be.equal(this.alice.address)
        expect(await this.rewardCalcs.allTeamAt(1)).to.be.equal(this.bob.address)
    })

    it("Check referral rewards", async () => {
        const underAlice_1 = ethers.Wallet.createRandom().connect(this.alice.provider);
        const underBob_1 = ethers.Wallet.createRandom().connect(this.bob.provider);

        await this.rewardCalcs.setReferral(underAlice_1.address, this.alice.address);
        await this.rewardCalcs.setReferral(underBob_1.address, this.bob.address);

        // Make Alice special
        await this.rewardCalcs.setCommissionForReferrer(this.alice.address, 50);

        this.checkCommission(underAlice_1.address, 1000, 150, 50)
        this.checkCommission(underBob_1.address,   1000, 150, 30)

        this.checkCommission(underAlice_1.address, 1000, 140, 40)
        this.checkCommission(underBob_1.address,   1000, 140, 30)

        this.checkCommission(underAlice_1.address, 1000, 100, 0)
        this.checkCommission(underBob_1.address,   1000, 100, 30)

        this.checkCommission(underAlice_1.address, 1000, 50, 0)
        this.checkCommission(underBob_1.address,   1000, 50, 30)

        this.checkCommission(underAlice_1.address, 1000, 25, 0)
        this.checkCommission(underBob_1.address,   1000, 25, 25)

        this.checkCommission(underAlice_1.address, 1000, 0, 0)
        this.checkCommission(underBob_1.address,   1000, 0, 0)
    })
})