const { expect, assert } = require("chai");
const { BigNumber, utils } = require("ethers");
const { ethers, upgrades } = require("hardhat");
const { mine } = require("@nomicfoundation/hardhat-network-helpers");


describe("Basic tests", function () {
    let bop, rop, ranks, msig, usdt;
    let admin, dev, user1, user2, user3;

    // eslint-disable-next-line no-undef
    before(async () => {
        [admin, dev, user1, user2, user3] = await ethers.getSigners();

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
            [100, 1000, 20],
            true
        );
      
        ranks.createRank(
            "Legendary",
            ["Min", "Max", "Commission"],
            [100, 1000, 20],
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

        // deploy multisig
      
        const MSig = await ethers.getContractFactory("MultiSigWallet");
        msig = await MSig.deploy([admin.address, user1.address, user2.address], 2);

        // deploy rop
      
        const ROP = await ethers.getContractFactory("RootOfPools_v2");
        rop = await upgrades.deployProxy(ROP, [usdt.address, ranks.address], {
            initializer: "initialize",
        });

        // deploy unionwallet

        const UnionWallet = await ethers.getContractFactory("UnionWallet");
        unionwallet = await upgrades.deployProxy(UnionWallet);

        // deploy bop

        const BOP = await ethers.getContractFactory("BranchOfPools");
        bop = await upgrades.deployProxy(BOP, [
            rop.address,
            100000000,
            1000,
            dev.address,
            usdt.address,
            100000
        ], {
            initializer: "init",
        });

        // config

        await rop.deployed();
        await rop.changeUnionWallet(unionwallet.address);

        await rop.connect(admin).addImage(example.address);
        await rop.connect(admin).transferOwnership(msig.address);

        console.log("done")

    });

    describe("Must be performed", function () {
        it ("Should be deployed", async function () {
            expect(await rop.deployed()).to.equal(rop);
        });
    });

});
