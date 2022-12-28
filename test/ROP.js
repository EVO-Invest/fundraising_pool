const {
  BN, // Big Number support
  constants, // Common constants, like the zero address and largest integers
  expectEvent, // Assertions for emitted events
  expectRevert, // Assertions for transactions that should fail
} = require("@openzeppelin/test-helpers");
const { inputToConfig } = require("@ethereum-waffle/compiler");
const { expect } = require("chai");
const { ethers, upgrades } = require("hardhat");
const BOPArtifacts = require("../artifacts/contracts/BOP.sol/BranchOfPools.json");

describe("Root of Pools", async function () {
  beforeEach(async function () {
    Ranks = await ethers.getContractFactory("Ranking");
    [owner, addr1, addr2, addr3, devUSDT, dev, fund, ...addrs] =
      await ethers.getSigners();

    ranks = await Ranks.deploy();
    own_ranks = ranks.connect(owner);
    own_ranks.createRank(
      "Common",
      ["Min", "Max", "Commission"],
      [100, 500, 20],
      true
    );

    own_ranks.createRank(
      "Rare",
      ["Min", "Max", "Commission"],
      [100, 1000, 20],
      true
    );

    own_ranks.createRank(
      "Legendary",
      ["Min", "Max", "Commission"],
      [100, 1000, 20],
      true
    );

    own_ranks.createRank(
      "Admin",
      ["Min", "Max", "Commission"],
      [0, 10000, 0],
      true
    );

    await own_ranks.giveRank(owner.address, "Admin");

    USDT = await ethers.getContractFactory("BEP20Token");
    usdt = await USDT.deploy(6);

    MSig = await ethers.getContractFactory("MultiSigWallet");
    msig = await MSig.deploy([owner.address, addr1.address, addr2.address], 2);
    await msig.deployed();

    Root = await ethers.getContractFactory("RootOfPools_v2");
    root = await upgrades.deployProxy(Root, [usdt.address, ranks.address], {
      initializer: "initialize",
    });

    UnionWallet = await ethers.getContractFactory("UnionWallet");
    unionwallet = await upgrades.deployProxy(UnionWallet);
    await unionwallet.deployed();

    await root.deployed();
    await root.changeUnionWallet(unionwallet.address);

    Branch = await ethers.getContractFactory("BranchOfPools");
    example = await Branch.deploy();

    await root.connect(owner).addImage(example.address);

    await root.connect(owner).transferOwnership(msig.address);
  });

  describe("Rank System", async function () {
    it("Parameters must be in the initial state", async function () {
      expect(await ranks.owner()).to.equal(owner.address);
      expect(await ranks.getNameParRank("Common")).to.have.lengthOf(3);
      expect(await ranks.getParRank("Common")).to.have.lengthOf(3);
    });
  });

  describe("Main Functional", async function () {
    beforeEach(async function () {
      tx1 = await example.populateTransaction.init(
        root.address,
        4500,
        100,
        devUSDT.address,
        usdt.address,
        0
      );

      tx = await root.populateTransaction.createPool("Test", 0, tx1.data);
      await msig.connect(owner).submitTransaction(root.address, 0, tx.data);
      id = (await msig.transactionCount()) - 1;
      await msig.connect(addr1).confirmTransaction(id);

      POOL = (String(await root.Pools(0)).split(','))[0];
      branch = new ethers.Contract(POOL, BOPArtifacts.abi, ethers.provider)
    });

    it("Check if the child contract is connected successfully", async function () {
      pools = await root.getPools();
      expect(pools).to.have.lengthOf(1);
      expect(pools[0][1]).to.equal("Test");
    });

    it("Emergency Stop Fundraising", async function () {
      //Give some usdt user addr1 and addr2
      await usdt.connect(owner).transfer(addr1.address, 1000000000); //1000 usdt
      await usdt.connect(owner).transfer(addr2.address, 1000000000);
      expect((await usdt.balanceOf(addr1.address)).toString()).to.equal(
        "1000000000"
      );
      expect((await usdt.balanceOf(addr2.address)).toString()).to.equal(
        "1000000000"
      );

      //Open deposit in Test pool

      tx1 = await branch.populateTransaction.startFundraising();
      tx2 = await root.populateTransaction.Calling("Test", tx1.data);
      await msig.connect(owner).submitTransaction(root.address, 0, tx2.data);
      id = (await msig.transactionCount()) - 1;
      await msig.connect(addr1).confirmTransaction(id);

      //Deposit in Test pool
      await usdt.connect(addr1).approve(branch.address, 1000000000);
      await usdt.connect(addr2).approve(branch.address, 1000000000);

      await root.connect(addr1).deposit("Test",500000000);
      await root.connect(addr2).deposit("Test",500000000);

      expect((await branch.myAllocationEmergency(addr1.address)).toString()).to.equal("500000000");
      expect((await branch.myAllocationEmergency(addr2.address)).toString()).to.equal("500000000");

      //Emergency stop
      tx1 = await branch.populateTransaction.stopEmergency();
      tx2 = await root.populateTransaction.Calling("Test", tx1.data);
      await msig.connect(owner).submitTransaction(root.address, 0, tx2.data);
      id = (await msig.transactionCount()) - 1;
      await msig.connect(addr1).confirmTransaction(id);

      //Users return funds
      tx1 = await branch.connect(addr1).paybackEmergency();
      tx1 = await branch.connect(addr2).paybackEmergency();

      //The money should come back
      expect((await usdt.balanceOf(addr1.address)).toString()).to.equal(
        "1000000000"
      );
      expect((await usdt.balanceOf(addr2.address)).toString()).to.equal(
        "1000000000"
      );
    });

    it("Should be through a full cycle of deposit and mandatory completion of collection with a double unlocks", async function () {
      //Give some usdt user addr1 and addr2
      await usdt.connect(owner).transfer(addr1.address, 1000000000); //1000 usdt
      await usdt.connect(owner).transfer(addr2.address, 1000000000);

      //Open deposit in Test pool
      tx1 = await branch.populateTransaction.startFundraising();
      tx2 = await root.populateTransaction.Calling("Test", tx1.data);
      await msig.connect(owner).submitTransaction(root.address, 0, tx2.data);
      id = (await msig.transactionCount()) - 1;
      await msig.connect(addr1).confirmTransaction(id);

      //Deposit in Test pool
      await usdt.connect(addr1).approve(branch.address, 1000000000);
      await usdt.connect(addr2).approve(branch.address, 1000000000);

      await root.connect(addr1).deposit("Test",500000000); //500 usdt
      await root.connect(addr2).deposit("Test",500000000);

      tx1 = await branch.populateTransaction.preSend(100000000);
      tx2 = await root.populateTransaction.Calling("Test", tx1.data);
      await msig.connect(owner).submitTransaction(root.address, 0, tx2.data);
      id = (await msig.transactionCount()) - 1;
      await msig.connect(addr1).confirmTransaction(id);

      expect((await usdt.balanceOf(devUSDT.address)).toString()).to.equal(
        "100000000"
      );

      //Close fundraising Test pool
      tx1 = await branch.populateTransaction.stopFundraising();
      tx2 = await root.populateTransaction.Calling("Test", tx1.data);
      await msig.connect(owner).submitTransaction(root.address, 0, tx2.data);
      id = (await msig.transactionCount()) - 1;
      await msig.connect(addr1).confirmTransaction(id);

      expect((await usdt.balanceOf(devUSDT.address)).toString()).to.equal(
        "800000000"
      ); // 800 usdt
      expect((await usdt.balanceOf(msig.address)).toString()).to.equal(
        "200000000"
      ); // 144 usdt

      //Create new token for entrust
      Token = await ethers.getContractFactory("SimpleToken");
      token = await Token.deploy("TEST", "TEST", 1000000);

      await token.connect(owner).transfer(dev.address, 1000000);
      await token.connect(dev).transfer(branch.address, 90000);

      tx1 = await branch.populateTransaction.entrustToken(token.address);
      tx2 = await root.populateTransaction.Calling("Test", tx1.data);
      await msig.connect(owner).submitTransaction(root.address, 0, tx2.data);
      id = (await msig.transactionCount()) - 1;
      await msig.connect(addr1).confirmTransaction(id);
      

      //Claim tokens
      await branch.connect(addr1).claim();
      await branch.connect(addr2).claim();


      expect((await token.balanceOf(addr1.address)).toString()).to.equal(
        "45000"
      );
      expect((await token.balanceOf(addr2.address)).toString()).to.equal(
        "45000"
      );
      expect(
        (
          await branch.connect(addr1).myCurrentAllocation(addr1.address)
        ).toString()
      ).to.equal("0");
      expect(
        (
          await branch.connect(addr2).myCurrentAllocation(addr2.address)
        ).toString()
      ).to.equal("0");

      //Next unlocks
      await token.connect(dev).transfer(branch.address, 90000);
      tx1 = await branch.populateTransaction.entrustToken(token.address);
      tx2 = await root.populateTransaction.Calling("Test", tx1.data);
      await msig.connect(owner).submitTransaction(root.address, 0, tx2.data);
      id = (await msig.transactionCount()) - 1;
      await msig.connect(addr1).confirmTransaction(id);

      //Claim tokens
      await branch.connect(addr1).claim();

      expect(
        (
          await branch.connect(addr1).myCurrentAllocation(addr1.address)
        ).toString()
      ).to.equal("0");
      expect(
        (
          await branch.connect(addr2).myCurrentAllocation(addr2.address)
        ).toString()
      ).to.equal("45000");

      await branch.connect(addr2).claim();

      expect(
        (
          await branch.connect(addr1).myCurrentAllocation(addr1.address)
        ).toString()
      ).to.equal("0");
      expect(
        (
          await branch.connect(addr2).myCurrentAllocation(addr2.address)
        ).toString()
      ).to.equal("0");
      expect((await token.balanceOf(addr1.address)).toString()).to.equal(
        "90000"
      );
      expect((await token.balanceOf(addr2.address)).toString()).to.equal(
        "90000"
      );
    });

    it("Checking basic math", async function () {
      a = 100000000; //Колличество денег
      b = 200000000;
      c = 300000000;
      d = 100000000;
      del_tokens = 2900; //Колличество токенов от разработчиков за 1 раз разлока

      a_k = Math.floor(a - a * 0.2); //С комиссиями
      b_k = Math.floor(b - b * 0.2);
      c_k = Math.floor(c - c * 0.2);

      toContract = Math.floor(//181
        (del_tokens * ((a + b + c) / 2)) / (a_k + b_k + c_k)
      );
      toOwner = Math.floor(del_tokens - toContract);
      console.log("toOwner first razlok- ", toOwner);

      a_tpu = Math.floor(toContract * (a_k / (a_k + b_k + c_k + d)));
      b_tpu = Math.floor(toContract * (b_k / (a_k + b_k + c_k + d)));
      c_tpu = Math.floor(toContract * (c_k / (a_k + b_k + c_k + d)));

      a_f = Math.floor(2 * a_tpu);
      b_f = Math.floor(2 * b_tpu);
      c_f = Math.floor(2 * c_tpu);

      console.log(a_f);
      console.log(b_f);
      console.log(c_f);

      //Give some usdt user addr1 and addr2
      await usdt.connect(owner).transfer(addr1.address, 1000000000); //1000 usdt
      await usdt.connect(owner).transfer(addr2.address, 1000000000);
      await usdt.connect(owner).transfer(addr3.address, 1000000000);

      //Open deposit in Test pool
      tx1 = await branch.populateTransaction.startFundraising();
      tx2 = await root.populateTransaction.Calling("Test", tx1.data);
      await msig.connect(owner).submitTransaction(root.address, 0, tx2.data);
      id = (await msig.transactionCount()) - 1;
      await msig.connect(addr1).confirmTransaction(id);

      //Get rank for addr2 and addr3
      await ranks.connect(owner).giveRank(addr2.address, "Rare");
      await ranks.connect(owner).giveRank(addr3.address, "Legendary");

      //Deposit in Test pool
      await usdt.connect(addr1).approve(branch.address, 1000000000);
      await usdt.connect(addr2).approve(branch.address, 1000000000);
      await usdt.connect(addr3).approve(branch.address, 1000000000);
      await usdt.connect(owner).approve(branch.address, 1000000000);

      await root.connect(addr1).deposit("Test",a);
      await root.connect(addr2).deposit("Test",b);
      await root.connect(addr3).deposit("Test",c);
      await root.connect(owner).deposit("Test",d);

      //Close fundraising Test pool
      tx1 = await branch.populateTransaction.stopFundraising();
      tx2 = await root.populateTransaction.Calling("Test", tx1.data);
      await msig.connect(owner).submitTransaction(root.address, 0, tx2.data);
      id = (await msig.transactionCount()) - 1;
      await msig.connect(addr1).confirmTransaction(id);

      //Create new token for entrust
      Token = await ethers.getContractFactory("SimpleToken");
      token = await Token.deploy("TEST", "TEST", 1000000);
      await token.connect(owner).transfer(dev.address, 1000000);
      await token.connect(dev).transfer(branch.address, del_tokens);
      
      tx1 = await branch.populateTransaction.entrustToken(token.address);
      tx2 = await root.populateTransaction.Calling("Test", tx1.data);
      await msig.connect(owner).submitTransaction(root.address, 0, tx2.data);
      id = (await msig.transactionCount()) - 1;
      await msig.connect(addr1).confirmTransaction(id);

      console.log(await branch.connect(addr1).myCurrentAllocation(addr1.address))
      console.log(await branch.connect(addr2).myCurrentAllocation(addr2.address))
      console.log(await branch.connect(addr3).myCurrentAllocation(addr3.address))
      console.log(await branch.connect(owner).myCurrentAllocation(owner.address))
      
      //Claim tokens
      await root.connect(addr1).claimName("Test");
      await root.connect(addr3).claimName("Test");

      //Next unlocks
      await token.connect(dev).transfer(branch.address, del_tokens);
      tx1 = await branch.populateTransaction.entrustToken(token.address);
      tx2 = await root.populateTransaction.Calling("Test", tx1.data);
      await msig.connect(owner).submitTransaction(root.address, 0, tx2.data);
      id = (await msig.transactionCount()) - 1;
      await msig.connect(addr1).confirmTransaction(id);

      //Claim tokens
      await branch.connect(addr1).claim();
      await branch.connect(addr2).claim();
      await branch.connect(owner).claim();
      await root.connect(addr3).claimName("Test");


      console.log("Msig - ",await token.balanceOf(msig.address));

      console.log("Addr1 - ",await token.balanceOf(addr1.address));
      console.log("Addr2 - ",await token.balanceOf(addr2.address));
      console.log("Addr3 - ",await token.balanceOf(addr3.address));
      console.log("Addr4 - ",await token.balanceOf(owner.address));
      console.log("Branch - ",await token.balanceOf(branch.address));
      console.log("CC - ", await branch._CURRENT_COMMISSION());
    });

    it("Checking Price Independence", async function () {
      //Give some usdt user addr1 and addr2
      await usdt.connect(owner).transfer(addr1.address, 1000000000); //1000 usdt
      await usdt.connect(owner).transfer(addr2.address, 1000000000);
      await usdt.connect(owner).transfer(addr3.address, 1000000000);

      //Open deposit in Test pool
      tx1 = await branch.populateTransaction.startFundraising();
      tx2 = await root.populateTransaction.Calling("Test", tx1.data);
      await msig.connect(owner).submitTransaction(root.address, 0, tx2.data);
      id = (await msig.transactionCount()) - 1;
      await msig.connect(addr1).confirmTransaction(id);

      //Deposit in Test pool
      await usdt.connect(addr1).approve(branch.address, 1000000000);
      await usdt.connect(addr2).approve(branch.address, 1000000000);
      await usdt.connect(addr3).approve(branch.address, 1000000000);

      await root.connect(addr1).deposit("Test",500000000); //500 usdt
      await root.connect(addr2).deposit("Test",500000000); //500
      await branch.connect(addr3).deposit(500000000); //500

      //Close fundraising Test pool
      tx1 = await branch.populateTransaction.stopFundraising();
      tx2 = await root.populateTransaction.Calling("Test", tx1.data);
      await msig.connect(owner).submitTransaction(root.address, 0, tx2.data);
      id = (await msig.transactionCount()) - 1;
      await msig.connect(addr1).confirmTransaction(id);

      //Create new token for entrust
      Token = await ethers.getContractFactory("SimpleToken");
      token = await Token.deploy("TEST", "TEST", 1000000);
      await token.connect(owner).transfer(dev.address, 1000000);
      await token.connect(dev).transfer(branch.address, 800);
      tx1 = await branch.populateTransaction.entrustToken(token.address);
      tx2 = await root.populateTransaction.Calling("Test", tx1.data);
      await msig.connect(owner).submitTransaction(root.address, 0, tx2.data);
      id = (await msig.transactionCount()) - 1;
      await msig.connect(addr1).confirmTransaction(id);

      //Claim tokens
      await branch.connect(addr1).claim();
      await branch.connect(addr2).claim();
      await branch.connect(addr3).claim();

      expect(
        (
          await branch.connect(addr1).myCurrentAllocation(addr1.address)
        ).toString()
      ).to.equal("0");
      expect(
        (
          await branch.connect(addr2).myCurrentAllocation(addr2.address)
        ).toString()
      ).to.equal("0");
      expect(
        (
          await branch.connect(addr3).myCurrentAllocation(addr3.address)
        ).toString()
      ).to.equal("0");

      //Next unlocks
      await token.connect(dev).transfer(branch.address, 800);
      tx1 = await branch.populateTransaction.entrustToken(token.address);
      tx2 = await root.populateTransaction.Calling("Test", tx1.data);
      await msig.connect(owner).submitTransaction(root.address, 0, tx2.data);
      id = (await msig.transactionCount()) - 1;
      await msig.connect(addr1).confirmTransaction(id);

      //Claim tokens
      await branch.connect(addr1).claim();
      await branch.connect(addr2).claim();
      await root.connect(addr3).claimName("Test");

      expect(
        (
          await branch.connect(addr1).myCurrentAllocation(addr1.address)
        ).toString()
      ).to.equal("0");
      expect(
        (
          await branch.connect(addr2).myCurrentAllocation(addr2.address)
        ).toString()
      ).to.equal("0");
      expect(
        (
          await branch.connect(addr3).myCurrentAllocation(addr3.address)
        ).toString()
      ).to.equal("0");

      expect((await token.balanceOf(addr1.address)).toString()).to.equal("533");
      expect((await token.balanceOf(addr2.address)).toString()).to.equal("533");
      expect((await token.balanceOf(addr3.address)).toString()).to.equal("533");
    });

    it("Data import check", async function(){
      let UsersNumber = 400; //Number of users participating in this test
      users = [];
      values = [];
      FR = UsersNumber * 100; //Share of each participant after subtracting the commission of 100
      CC = FR * 0,2;

      for(i = 0; i < UsersNumber; i++){
        users[i] = ethers.Wallet.createRandom().address;
        values[i] = 100;
        //console.log(users[i]);
      }

      tx1 = await branch.populateTransaction.importTable(users, values);
      tx2 = await root.populateTransaction.Calling("Test", tx1.data);
      await msig.connect(owner).submitTransaction(root.address, 0, tx2.data);
      id = (await msig.transactionCount()) - 1;
      await msig.connect(addr1).confirmTransaction(id);

      tx1 = await branch.populateTransaction.importFR(FR);
      tx2 = await root.populateTransaction.Calling("Test", tx1.data);
      await msig.connect(owner).submitTransaction(root.address, 0, tx2.data);
      id = (await msig.transactionCount()) - 1;
      await msig.connect(addr1).confirmTransaction(id);

      tx1 = await branch.populateTransaction.importCC(CC);
      tx2 = await root.populateTransaction.Calling("Test", tx1.data);
      await msig.connect(owner).submitTransaction(root.address, 0, tx2.data);
      id = (await msig.transactionCount()) - 1;
      await msig.connect(addr1).confirmTransaction(id);

      tx1 = await branch.populateTransaction.closeImport();
      tx2 = await root.populateTransaction.Calling("Test", tx1.data);
      await msig.connect(owner).submitTransaction(root.address, 0, tx2.data);
      id = (await msig.transactionCount()) - 1;
      await msig.connect(addr1).confirmTransaction(id);

      for(i = 0; i < UsersNumber; i++){
        expect(await branch.myAllocation(users[i])).to.equal(100);
      }

    });

    it("Check max value deposit", async function(){
      await usdt.connect(owner).transfer(addr1.address, "115792089237316195423570985008687907853269984665640564039457584007913129639935");
      await usdt.connect(addr1).approve(branch.address, "115792089237316195423570985008687907853269984665640564039457584007913129639935");

      //Open deposit in Test pool
      tx1 = await branch.populateTransaction.startFundraising();
      tx2 = await root.populateTransaction.Calling("Test", tx1.data);
      await msig.connect(owner).submitTransaction(root.address, 0, tx2.data);
      id = (await msig.transactionCount()) - 1;
      await msig.connect(addr1).confirmTransaction(id);

      expect(root.connect(addr1).deposit("Test","Test", "115792089237316195423570985008687907853269984665640564039457584007913129639935")).to.be.reverted;
    });

    it("Check +1 token bag", async function(){
      await usdt.connect(owner).transfer(addr1.address, 1000000000); //1000 usdt
      await usdt.connect(owner).transfer(addr2.address, 1000000000);

      //Open deposit in Test pool
      tx1 = await branch.populateTransaction.startFundraising();
      tx2 = await root.populateTransaction.Calling("Test", tx1.data);
      await msig.connect(owner).submitTransaction(root.address, 0, tx2.data);
      id = (await msig.transactionCount()) - 1;
      await msig.connect(addr1).confirmTransaction(id);

      //Deposit in Test pool
      await usdt.connect(addr1).approve(branch.address, 1000000000);
      await usdt.connect(addr2).approve(branch.address, 1000000000);

      await usdt.connect(owner).transfer(branch.address, 1);

      await root.connect(addr1).deposit("Test",500000000); //500 usdt
      await root.connect(addr2).deposit("Test",500000000);

      //Close fundraising Test pool
      tx1 = await branch.populateTransaction.stopFundraising();
      tx2 = await root.populateTransaction.Calling("Test", tx1.data);
      await msig.connect(owner).submitTransaction(root.address, 0, tx2.data);
      id = (await msig.transactionCount()) - 1;
      await msig.connect(addr1).confirmTransaction(id);

      expect((await usdt.balanceOf(devUSDT.address)).toString()).to.equal(
        "800000000"
      ); // 800 usdt
      expect((await usdt.balanceOf(msig.address)).toString()).to.equal(
        "200000001"
      ); // 200 usdt

      //Create new token for entrust
      Token = await ethers.getContractFactory("SimpleToken");
      token = await Token.deploy("TEST", "TEST", 1000000);

      await token.connect(owner).transfer(dev.address, 1000000);
      await token.connect(dev).transfer(branch.address, 90000);

      await token.connect(dev).transfer(branch.address, 1);

      tx1 = await branch.populateTransaction.entrustToken(token.address);
      tx2 = await root.populateTransaction.Calling("Test", tx1.data);
      await msig.connect(owner).submitTransaction(root.address, 0, tx2.data);
      id = (await msig.transactionCount()) - 1;
      await msig.connect(addr1).confirmTransaction(id);

      //Claim tokens
      await branch.connect(addr1).claim();
      await branch.connect(addr2).claim();

      expect(
        (
          await branch.connect(addr1).myCurrentAllocation(addr1.address)
        ).toString()
      ).to.equal("0");
      expect(
        (
          await branch.connect(addr2).myCurrentAllocation(addr2.address)
        ).toString()
      ).to.equal("0");
      expect((await token.balanceOf(addr1.address)).toString()).to.equal(
        "45000"
      );
      expect((await token.balanceOf(addr2.address)).toString()).to.equal(
        "45000"
      );

      //Next unlocks
      await token.connect(dev).transfer(branch.address, 90000);
      tx1 = await branch.populateTransaction.entrustToken(token.address);
      tx2 = await root.populateTransaction.Calling("Test", tx1.data);
      await msig.connect(owner).submitTransaction(root.address, 0, tx2.data);
      id = (await msig.transactionCount()) - 1;
      await msig.connect(addr1).confirmTransaction(id);

      //Claim tokens
      await branch.connect(addr1).claim();
      await branch.connect(addr2).claim();

      expect(
        (
          await branch.connect(addr1).myCurrentAllocation(addr1.address)
        ).toString()
      ).to.equal("0");
      expect(
        (
          await branch.connect(addr2).myCurrentAllocation(addr2.address)
        ).toString()
      ).to.equal("0");
      expect((await token.balanceOf(addr1.address)).toString()).to.equal(
        "90000"
      );
      expect((await token.balanceOf(addr2.address)).toString()).to.equal(
        "90000"
      );
    });

    it("Check for a refund from the developer", async function(){
      await usdt.connect(owner).transfer(addr1.address, 1000000000); //1000 usdt
      await usdt.connect(owner).transfer(addr2.address, 1000000000);

      //Open deposit in Test pool
      tx1 = await branch.populateTransaction.startFundraising();
      tx2 = await root.populateTransaction.Calling("Test", tx1.data);
      await msig.connect(owner).submitTransaction(root.address, 0, tx2.data);
      id = (await msig.transactionCount()) - 1;
      await msig.connect(addr1).confirmTransaction(id);

      //Deposit in Test pool
      await usdt.connect(addr1).approve(branch.address, 1000000000);
      await usdt.connect(addr2).approve(branch.address, 1000000000);

      await usdt.connect(owner).transfer(branch.address, 1);

      await root.connect(addr1).deposit("Test",500000000); //500 usdt
      await root.connect(addr2).deposit("Test",500000000);

      //Close fundraising Test pool
      tx1 = await branch.populateTransaction.stopFundraising();
      tx2 = await root.populateTransaction.Calling("Test", tx1.data);
      await msig.connect(owner).submitTransaction(root.address, 0, tx2.data);
      id = (await msig.transactionCount()) - 1;
      await msig.connect(addr1).confirmTransaction(id);

      expect((await usdt.balanceOf(devUSDT.address)).toString()).to.equal(
        "800000000"
      ); // 800 usdt
      expect((await usdt.balanceOf(msig.address)).toString()).to.equal(
        "200000001"
      );

      //Refund from dev
      await usdt.connect(devUSDT).transfer(branch.address, 800000000);
      
      //Refund from admin
      tx = await usdt.populateTransaction.transfer(branch.address, 200000001);
      await msig.connect(owner).submitTransaction(usdt.address, 0, tx.data);
      id = (await msig.transactionCount()) - 1;
      await msig.connect(addr1).confirmTransaction(id);

      //Try stop
      tx1 = await branch.populateTransaction.stopEmergency();
      tx2 = await root.populateTransaction.Calling("Test", tx1.data);
      await msig.connect(owner).submitTransaction(root.address, 0, tx2.data);
      id = (await msig.transactionCount()) - 1;
      await msig.connect(addr1).confirmTransaction(id);

      expect(await branch._state()).to.equal(4);

    });

    it("Pre-shipment check", async function(){
      await usdt.connect(owner).transfer(owner.address, 4500000000);

      tx1 = await branch.populateTransaction.startFundraising();
      tx2 = await root.populateTransaction.Calling("Test", tx1.data);
      await msig.connect(owner).submitTransaction(root.address, 0, tx2.data);
      id = (await msig.transactionCount()) - 1;
      await msig.connect(addr1).confirmTransaction(id);

      await usdt.connect(owner).approve(branch.address, 4500000000);

      await root.connect(owner).deposit("Test",4500000000); 

      expect(await branch._state()).to.equal(2);

      tx1 = await branch.populateTransaction.preSend(500000000);
      tx2 = await root.populateTransaction.Calling("Test", tx1.data);
      await msig.connect(owner).submitTransaction(root.address, 0, tx2.data);
      id = (await msig.transactionCount()) - 1;
      await msig.connect(addr1).confirmTransaction(id);

      expect((await usdt.balanceOf(devUSDT.address)).toString()).to.  equal(
        "500000000"
      );
    });
  });
});
