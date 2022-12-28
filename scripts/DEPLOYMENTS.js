// Here we are emulating named addresses from hardhat-deploy.

const DATA = {
  UnionWallet: {
    tbsc:  null,
  }
};

module.exports = (alias) => {
  return DATA[alias][hre.network.name] || DATA[alias]["default"]
}

