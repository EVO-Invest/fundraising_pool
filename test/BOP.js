const { expect, assert } = require("chai");
const { BigNumber, utils } = require("ethers");
const { ethers, upgrades } = require("hardhat");
const { mine } = require("@nomicfoundation/hardhat-network-helpers");


class Investor {
    constructor() {
        this.wallets = [];
        this.amountInvested = 0;
    }

    addWallet(wallet) {
        this.wallets.push(wallet)
    }
}


describe("BOP Megatest", function () {
    let rop, ranks, usdt, unionwallet, rewardCalcs, bopImage, token;
    let admin, dev;
    let getDirectPoolAccess;

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

        // deploy token

        const TOKEN = USDT;  // shortcut
        token = await TOKEN.deploy(9);

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
                2524608000 /* somewhat 2050/1/1 */
            )).data);
        const createBopEffects = await createBopTx.wait()
        const responseLogs = createBopEffects.events.filter(e => e.event === "Response");
        expect(responseLogs).to.have.length(1)
        expect(responseLogs[0].args.success).to.be.true

        getDirectPoolAccess = async () => {
            const poolAddress = (await rop.Pools(0)).pool
            return BOP.attach(poolAddress)
        }
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
        for (let investorID = 0; investorID < 500; ++investorID) {
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
        const poolAddress = (await rop.Pools(0)).pool
        for (let i = 0; i < investors.length; ++i) {
            const payment = ((i % 5) + 1) * 100;
            totalPayments += payment
            const walletIndex = i % investors[i].wallets.length;
            const wallet = investors[i].wallets[walletIndex]
            // OMG. BOP is calling transferFrom, not ROP. Pretty dirty.
            const approvalTx = await usdt.connect(wallet).approve(poolAddress, payment * 1000000)
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

            /* Not nice to hardcode it here, but it is easier... */
            const ranker = i % 17;
            if (ranker <= 13) {
                investors[i].totalPayments += 0.8 * payment;
            } else if (ranker < 16) {
                investors[i].totalPayments += 0.9 * payment;
            } else if (ranker === 16) {
                investors[i].totalPayments += payment;
            }

            if (totalPayments >= 119500) {
                console.log(`OK, closing fundraising.`)
                break
            }
            // if (parseInt(remainingUSD.toString()) < 100) {
            //     console.log(`OK, closing fundraising, as only ${remainingUSD.toString()} remained`)
            //     break
            // }
        }
    })

    it("Allows to send 1% of collected USD to the project during the fundraising", async () => {
        const presendTxRaw = await bopImage.populateTransaction.preSend("1000" + "000000")
        const presendTx = await rop.Calling("First Pool", presendTxRaw.data);
        const effects = await presendTx.wait()
        const responseLogs = effects.events.filter(e => e.event === "Response");
        expect(responseLogs).to.have.length(1)
        expect(responseLogs[0].args.success).to.be.true

        const devBalance = await usdt.balanceOf(dev.address);
        expect(devBalance.div("1000000").toString()).to.be.eq("1000")
    })

    it("Closes fund", async () => {
        const stopFundraisingTxRaw = await bopImage.populateTransaction.stopFundraising()
        const stopFundraisingTx = await rop.Calling("First Pool", stopFundraisingTxRaw.data);
        const effects = await stopFundraisingTx.wait()
        const responseLogs = effects.events.filter(e => e.event === "Response");
        expect(responseLogs).to.have.length(1)
        expect(responseLogs[0].args.success).to.be.true
    })

    it("Allows to send 1% of collected USD to the project before token announced", async () => {
        const presendTxRaw = await bopImage.populateTransaction.preSend("1000" + "000000")
        const presendTx = await rop.Calling("First Pool", presendTxRaw.data);
        const effects = await presendTx.wait()
        const responseLogs = effects.events.filter(e => e.event === "Response");
        expect(responseLogs).to.have.length(1)
        expect(responseLogs[0].args.success).to.be.true

        const devBalance = await usdt.balanceOf(dev.address);
        expect(devBalance.div("1000000").toString()).to.be.eq("2000")
    })

    it("Allows to owner to collect comissions", async () => {
        const adminBalanceBeforeCollectingComissions = await usdt.balanceOf(admin.address)

        const collectComissionsTxRaw = await bopImage.populateTransaction.getCommission()
        const collectComissionsTx = await rop.Calling("First Pool", collectComissionsTxRaw.data);
        const effects = await collectComissionsTx.wait()
        const responseLogs = effects.events.filter(e => e.event === "Response");
        expect(responseLogs).to.have.length(1)
        expect(responseLogs[0].args.success).to.be.true

        const adminBalanceAfterCollectingComissions = await usdt.balanceOf(admin.address)

        expect(adminBalanceAfterCollectingComissions
                .sub(adminBalanceBeforeCollectingComissions)
                .div("1000000").toString()).to.be.eq("5841");
    })

    it("Does not allow to team to collect comissions", async () => {
        const crewBalanceBeforeCollectingComissions = await usdt.balanceOf(team[1].address)
        const pool = await getDirectPoolAccess()

        const collectComissionsTx = await pool.connect(team[1]).getCommission()
        await collectComissionsTx.wait()

        const crewBalanceAfterCollectingComissions = await usdt.balanceOf(team[1].address)

        expect(crewBalanceAfterCollectingComissions
                .sub(crewBalanceBeforeCollectingComissions).toString()).to.be.eq("0")
    })

    it("Does not allow to referrals to collect comissions", async () => {
        const referralBalanceBeforeCollectingComissions = await usdt.balanceOf(investors[1].wallets[0].address)
        const pool = await getDirectPoolAccess()

        const collectComissionsTx = await pool.connect(investors[1].wallets[0]).getCommission()
        await collectComissionsTx.wait()

        const referralBalanceAfterCollectingComissions = await usdt.balanceOf(investors[1].wallets[0].address)

        expect(referralBalanceAfterCollectingComissions
                .sub(referralBalanceBeforeCollectingComissions).toString()).to.be.eq("0")
    })

    it("Sets token address", async () => {
        const entrustTxRaw = await bopImage.populateTransaction.entrustToken(token.address)
        const entrustTx = await rop.Calling("First Pool", entrustTxRaw.data);
        const effects = await entrustTx.wait()
        const responseLogs = effects.events.filter(e => e.event === "Response");
        expect(responseLogs).to.have.length(1)
        expect(responseLogs[0].args.success).to.be.true
    })

    it("Allows to send remaning collected USD to the project", async () => {
        const presendTxRaw = await bopImage.populateTransaction.preSend("98000" + "000000")
        const presendTx = await rop.Calling("First Pool", presendTxRaw.data);
        const effects = await presendTx.wait()
        const responseLogs = effects.events.filter(e => e.event === "Response");
        expect(responseLogs).to.have.length(1)
        expect(responseLogs[0].args.success).to.be.true

        const devBalance = await usdt.balanceOf(dev.address);
        expect(devBalance.div("1000000").toString()).to.be.eq("100000")
    })

    it("Allows to some referrals to collect comissions (others will collect later)", async () => {
        const pool = await getDirectPoolAccess()
        for (let i = 0; i < 10; ++i) {
            const wallet = investors[i].wallets[investors[i].wallets.length - 1];
            const referralBalanceBeforeCollectingComissions = await usdt.balanceOf(wallet.address)

            const collectComissionsTx = await pool.connect(wallet).getCommission()
            await collectComissionsTx.wait()

            const referralBalanceAfterCollectingComissions = await usdt.balanceOf(wallet.address)

            console.log(
                `Referal ${i} got ${referralBalanceAfterCollectingComissions.sub(referralBalanceBeforeCollectingComissions).div("1000000")} in comissions`
            );
        }
    })

    it("Allows to the person in salary in stable to receive salary", async () => {
        const crewBalanceBeforeCollectingComissions = await usdt.balanceOf(team[1].address)
        const pool = await getDirectPoolAccess()

        const collectComissionsTx = await pool.connect(team[1]).getCommission()
        await collectComissionsTx.wait()

        const crewBalanceAfterCollectingComissions = await usdt.balanceOf(team[1].address)

        expect(crewBalanceAfterCollectingComissions
                .sub(crewBalanceBeforeCollectingComissions)
                .div("1000000").toString()).to.be.eq("500")
    })

    it("Receives some token", async () => {
        const pool = await getDirectPoolAccess();
        // So, we got 10M tokens for 100K.
        const tx = await token.transfer(pool.address, "10000000" + "000000000");
        await tx.wait()
    })

    it("Allows to remaining referrals to collect comissions", async () => {
        const pool = await getDirectPoolAccess()
        for (let i = 10; i < 30; ++i) {
            const wallet = investors[i].wallets[investors[i].wallets.length - 1];
            const referralBalanceBeforeCollectingComissions = await usdt.balanceOf(wallet.address)

            const collectComissionsTx = await pool.connect(wallet).getCommission()
            await collectComissionsTx.wait()

            const referralBalanceAfterCollectingComissions = await usdt.balanceOf(wallet.address)

            console.log(
                `Referal ${i} got ${referralBalanceAfterCollectingComissions.sub(referralBalanceBeforeCollectingComissions).div("1000000")} in comissions`
            );
        }
    })

    it("After sending payments and collecting comissions, remaining balance should be almost 0", async () => {
        const pool = await getDirectPoolAccess();
        const bopContractBalance = await usdt.balanceOf(pool.address)
        expect(bopContractBalance.div("1000000").toString()).to.be.eq("0")
    })

    it("Check claims")

    it("Check salary claims")    
    
    it("Receives more token", async () => {})

    it("Check claims")

    it("Check salary claims")    
});
