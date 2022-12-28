const { expect, assert } = require("chai");
const { BigNumber, utils } = require("ethers");
const { ethers, upgrades } = require("hardhat");
const helpers = require("@nomicfoundation/hardhat-network-helpers");
require("dotenv").config();

const ROPContract = require('../artifacts/contracts/ROP.sol/RootOfPools_v2.json');
const BOPContract = require('../artifacts/contracts/BOP.sol/BranchOfPools.json');
const ERC20Contract = require('../artifacts/@openzeppelin/contracts/token/ERC20/ERC20.sol/ERC20.json');

describe("Forking tests", function () {
    let _, admin, user1;
    let rop, bop, usd;

    before(async () => {
        [_] = await ethers.getSigners();

        await helpers.impersonateAccount('0x9E5712ad09408caA834378c5C0147C475E442541');
        let donater = await ethers.getSigner('0x9E5712ad09408caA834378c5C0147C475E442541');
        donater.sendTransaction({ to: '0xa15fd73baae40a50e553bf88e0e2bdf76b1f665f', value: utils.parseEther('1') });

        await helpers.impersonateAccount('0xa15fd73baae40a50e553bf88e0e2bdf76b1f665f');
        admin = await ethers.getSigner('0xa15fd73baae40a50e553bf88e0e2bdf76b1f665f');

        await helpers.impersonateAccount('0x6487dd02cc69915e0deafbb0844285173cbc4c31');
        user1 = await ethers.getSigner('0x6487dd02cc69915e0deafbb0844285173cbc4c31');

        rop = new ethers.Contract("0x466489c27bD7f547f48c0BFc6d6057E503083cD3", ROPContract.abi);
        bop = new ethers.Contract("0x52059863db2ff84944f14d8e5236e31c98083642", BOPContract.abi);
        usd = new ethers.Contract("0x8AC76a51cc950d9822D68b83fE1Ad97B32Cd580d", ERC20Contract.abi);
    });

    it("Should transfer money back to bop", async function () {
        await helpers.impersonateAccount('0xA15Fd73bAae40A50e553bF88e0E2BDf76b1f665f');
        let tempAdmin = await ethers.getSigner('0xA15Fd73bAae40A50e553bF88e0E2BDf76b1f665f');

        await helpers.impersonateAccount('0x4982085C9e2F89F2eCb8131Eca71aFAD896e89CB');
        let project1 = await ethers.getSigner('0x4982085C9e2F89F2eCb8131Eca71aFAD896e89CB');
        await helpers.impersonateAccount('0x62a0b5c2ea4fd07629bae6d319baf6dffaa10a7b');
        let project = await ethers.getSigner('0x62a0b5c2ea4fd07629bae6d319baf6dffaa10a7b');

        await usd.connect(tempAdmin).transfer(bop.address, BigNumber.from("495000000000000000000"));

        await usd.connect(project1).transfer(project.address, BigNumber.from('5005000000000000000000'));
        await usd.connect(project).transfer(bop.address, BigNumber.from('5005000000000000000000'));
    })

    it("Should set alarm", async function () {
        expect(await bop.connect(_)._state()).to.equal(2);

        const presendTxRaw = await bop.populateTransaction.stopEmergency();
        const presendTx = await rop.connect(admin).Calling("639264c3ae724", presendTxRaw.data);
        const effects = await presendTx.wait()
        const responseLogs = effects.events.filter(e => e.event === "Response");

        expect(await bop.connect(_)._state()).to.equal(4);
    });

    it("Should transfer money back to users", async function () {
        let user1StartBalance = await usd.connect(user1).balanceOf(user1.address);

        const presendTxRaw = await bop.connect(user1).paybackEmergency();

        let user1EndBalance = await usd.connect(user1).balanceOf(user1.address);
        console.log(user1EndBalance - user1StartBalance);
    })

});
