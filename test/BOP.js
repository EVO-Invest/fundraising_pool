const { expect, assert } = require("chai");
const { BigNumber, utils } = require("ethers");
const { ethers, upgrades } = require("hardhat");
const { mine } = require("@nomicfoundation/hardhat-network-helpers");


class Investor {
    constructor() {
        this.wallets = [];
    }

    addWallet(wallet) {
        this.wallets.push(wallet)
    }
}


describe("BOP Megatest", function () {
    let rop, ranks, usdt, unionwallet, rewardCalcs, bopImage;
    let admin, dev;

    let investors = []
    let team = []

    // eslint-disable-next-line no-undef
    before(async () => {
        [admin, dev] = await ethers.getSigners();

        // deploy ranking

        const Ranks = await ethers.getContractFactory("Ranking");
        ranks = await Ranks.deploy();

        ranks.createRank(
            "Common",
            ["Min", "Max", "Commission"],
            [100, 500, 20],
            true
        );
      
        ranks.createRank(
            "Rare",
            ["Min", "Max", "Commission"],
            [100, 1000, 10],
            true
        );
      
        ranks.createRank(
            "Legendary",
            ["Min", "Max", "Commission"],
            [100, 1000, 0],
            true
        );
      
        ranks.createRank(
            "Admin",
            ["Min", "Max", "Commission"],
            [0, 10000, 0],
            true
        );
      
        await ranks.giveRanks([admin.address], "Admin");

         // deploy usdt
         const USDT = await ethers.getContractFactory("BEP20Token");
         usdt = await USDT.deploy(6);

        // deploy unionwallet
        
        const UnionWallet = await ethers.getContractFactory("UnionWallet");
        unionwallet = await upgrades.deployProxy(UnionWallet);
         
         // deploy rop
         
        const ROP = await ethers.getContractFactory("RootOfPools_v2");
        rop = await upgrades.deployProxy(ROP, [usdt.address, ranks.address], {
             initializer: "initialize",
        });
        const ropSetUnionwalletTx = await rop.changeUnionWallet(unionwallet.address)
        await ropSetUnionwalletTx.wait()

        // deploy reward calcs

        const RewardCalcs = await ethers.getContractFactory("RewardCalcs");
        rewardCalcs = await upgrades.deployProxy(RewardCalcs, [admin.address, rop.address, unionwallet.address])
        const setRewardsContractInRopTx = await rop.changeRewardCalcs(rewardCalcs.address);
        await setRewardsContractInRopTx.wait()

        // deploy bop image
        
        const BOP = await ethers.getContractFactory("BranchOfPools");
        bopImage = await BOP.deploy();
        await bopImage.deployed();

        // Add deployed BOP as an image
        const addBopToRopTx = await rop.addImage(bopImage.address);
        await addBopToRopTx.wait();

        // Check
        let imageNum = 0;
        while (true) {
            const imageAddr = await rop.Images(imageNum);
            if (imageAddr == bopImage.address)
            break;
            ++imageNum;
        }

        // Some other preparations
        await setSalaries();
        await generateWalletsAndFundThem();
        await overrideCommissionsForSomeReferrals();
        
        // And deploy BOP from ROP.
        const createBopTx = await rop.createPool("First Pool", imageNum, 
            (await bopImage.populateTransaction.init(
                rop.address,
                100000,
                100,
                dev.address,
                usdt.address,
                100000
            )).data);
        const createBopEffects = await createBopTx.wait()
        const responseLogs = createBopEffects.events.filter(e => e.event === "Response");
        expect(responseLogs).to.have.length(1)
        expect(responseLogs[0].args.success).to.be.true
    });

    const setSalaries = async () => {
        for (let prc of [1, 5, 10]) {
            const wallet = ethers.Wallet.createRandom().connect(admin.provider)
            team.push(wallet)
            const tx = await rewardCalcs.addTeamMember(wallet.address, prc, 1);
            await tx.wait()
            await fundWallet(wallet.address)
        }

        const tx = await rewardCalcs.connect(team[1]).updateMyRewardTypeChoice(0);
        await tx.wait()
    }

    const fundWallet = async (address) => {
        const fundWithEthers = await admin.sendTransaction({from: admin.address, to: address, value: "100000000000000000"})
        await fundWithEthers.wait()

        const fundWithBUSD = await usdt.transfer(address, "1500000000") // 1500 USD
        await fundWithBUSD.wait()
    }

    const overrideCommissionsForSomeReferrals = async () => {
        const tx = await rewardCalcs.setCommissionForReferrer(investors[4].wallets[0].address, 50);
        await tx.wait()
    }

    const generateWalletsAndFundThem = async () => {
        for (let investorID = 0; investorID < 1000; ++investorID) {
            if (investorID % 100 == 0) console.log(`Generated ${investors.length} investors`);
            const newInvestor = new Investor();
            const mainWallet = ethers.Wallet.createRandom().connect(admin.provider)
            await fundWallet(mainWallet.address)
            newInvestor.addWallet(mainWallet)
            investors.push(newInvestor)

            // 25% users have 2 wallets, 25% have 3.
            const extraWallets = investorID % 4;
            let lastExtraWallet = mainWallet
            if (extraWallets > 1) {
                for (let i = 1; i < extraWallets; ++i) {
                    const extraWallet = ethers.Wallet.createRandom().connect(admin.provider)
                    await fundWallet(extraWallet.address)
                    newInvestor.addWallet(extraWallet)
                    const attachTx = await unionwallet.connect(lastExtraWallet).attachToIdentity(extraWallet.address)
                    await attachTx.wait()
                    lastExtraWallet = extraWallet
                }
            }

            // first 20 people are acting as referals. Some people don't have referals.
            const referalId = investorID % 30;
            if (referalId < 20 && investorID > 20) {
                const setReferalTx = await rewardCalcs.setReferral(mainWallet.address, investors[referalId].wallets[0].address)
                await setReferalTx.wait()
            }

            // Assign ranks
            const ranker = investorID % 17;
            let rankTx;
            if (ranker === 13) {
                rankTx = await ranks.giveRanks([mainWallet.address], "Common")
            } else if (ranker > 13 && ranker < 16) {
                rankTx = await ranks.giveRanks([mainWallet.address], "Rare")
            } else if (ranker === 16) {
                rankTx = await ranks.giveRanks([mainWallet.address], "Legendary")
            }
            if (rankTx) await rankTx.wait()
        }
    }

    it ("Should be Unpaused successfully", async () => {
        const txRaw = await bopImage.populateTransaction.startFundraising();
        const tx = await rop.Calling("First Pool", txRaw.data);
        const effects = await tx.wait()
        const responseLogs = effects.events.filter(e => e.event === "Response");
        expect(responseLogs).to.have.length(1)
        expect(responseLogs[0].args.success).to.be.true
    });

    it ("Computes required amount right after open correctly", async () => {
        const getAdminPaymentTxRaw = await bopImage.populateTransaction.requiredAmountToCloseFundraising()
        const getAdminPaymentTx = await rop.Calling("First Pool", getAdminPaymentTxRaw.data);
        const effects = await getAdminPaymentTx.wait()
        const responseLogs = effects.events.filter(e => e.event === "Response");
        expect(responseLogs).to.have.length(1)
        expect(responseLogs[0].args.success).to.be.true
        const remaining = new ethers.BigNumber.from(responseLogs[0].args[2])
        const remainingUSD = remaining.div("1000000")
        expect(remainingUSD.toString()).to.be.equal("100500")
    })

    let totalPayments = 0
    it ("Collects payments", async () => {
        for (let i = 0; i < investors.length; ++i) {
            const payment = ((i % 5) + 1) * 100;
            totalPayments += payment
            const walletIndex = i % investors[i].wallets.length;
            const wallet = investors[i].wallets[walletIndex]
            // OMG. BOP is calling transferFrom, not ROP. Pretty dirty.
            const approvalTx = await usdt.connect(wallet).approve(
                (await rop.Pools(0)).pool,
                payment * 1000000
            )
            await approvalTx.wait()
            const depositTx = await rop.connect(wallet).deposit("First Pool", payment * 1000000)
            await depositTx.wait()

            const getAdminPaymentTxRaw = await bopImage.populateTransaction.requiredAmountToCloseFundraising()
            const getAdminPaymentTx = await rop.Calling("First Pool", getAdminPaymentTxRaw.data);
            const effects = await getAdminPaymentTx.wait()
            const responseLogs = effects.events.filter(e => e.event === "Response");
            expect(responseLogs).to.have.length(1)
            expect(responseLogs[0].args.success).to.be.true
            const remaining = new ethers.BigNumber.from(responseLogs[0].args[2])
            const remainingUSD = remaining.div("1000000")

            console.log(`${i}. Depositing ${payment} from ${wallet.address}. Total deposited ${totalPayments}. Remaining ${remainingUSD.toString()}`);

            if (parseInt(remainingUSD.toString()) < 100) {
                console.log(`OK, closing fundraising, as only ${remainingUSD.toString()} remained`)
            }
        }
    })
});
