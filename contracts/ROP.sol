//SPDX-License-Identifier: GNU GPLv3
pragma solidity ^0.8.2;

import "@openzeppelin/contracts/utils/Strings.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol";
import "@openzeppelin/contracts-upgradeable/utils/AddressUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts/proxy/Clones.sol";

import "./Ranking.sol";
import "./BOP.sol";
import "./RewardCalcs.sol";

/// @title The root of the poole tree. Allows you to close control of a large
/// number of pools to 1 address. Simplifies user interaction with a large number of pools.
/// @author Nethny
/// @dev Must be the owner of child contracts, to short-circuit the administrative
/// rights to one address.
contract RootOfPools_v2 is Initializable, OwnableUpgradeable {
    using AddressUpgradeable for address;
    using Strings for uint256;

    struct Pool {
        address pool;
        string name;
    }

    Pool[] public Pools;

    mapping(string => address) private _poolsTable;

    address public _usdAddress;
    address public _rankingAddress;

    address[] public Images;

    mapping(address => bool) private _imageTable;

    RewardCalcs public _rewardCalcs;
    address public _unionWallet;

    event PoolCreated(string name, address pool);
    event ImageAdded(address image);
    event Response(address to, bool success, bytes data);

    modifier shouldExist(string calldata name) {
        require(
            _poolsTable[name] != address(0),
            "ROOT: Selected pool does not exist!"
        );
        _;
    }

    /// @notice Replacement of the constructor to implement the proxy
    function initialize(address usdAddress, address rankingAddress)
        external
        initializer
    {
        require(
            usdAddress != address(0),
            "INIT: The usdAddress must not be zero."
        );
        require(
            rankingAddress != address(0),
            "INIT: The rankingAddress must not be zero."
        );

        __Ownable_init();
        _usdAddress = usdAddress;
        _rankingAddress = rankingAddress;
    }

    function changeRewardCalcs(RewardCalcs newCalcs) public onlyOwner {
        _rewardCalcs = newCalcs;
    }

    function changeUnionWallet(address newUnionWallet) public onlyOwner {
        _unionWallet = newUnionWallet;
    }

    function addImage(address image) external onlyOwner {
        require(_imageTable[image] != true);

        Images.push(image);
        _imageTable[image] = true;

        emit ImageAdded(image);
    }

    /// @notice Allows you to attach a new pool (branch contract)
    /// @dev Don't forget to run the init function
    function createPool(
        string calldata name,
        uint256 imageNumber,
        bytes calldata dataIn
    ) external onlyOwner {
        require(
            imageNumber <= Images.length,
            "ROOT: Such an image does not exist"
        );
        require(
            _poolsTable[name] == address(0),
            "ROOT: Pool with this name already exists!"
        );

        address pool = Clones.clone(Images[imageNumber]);
        _rewardCalcs.addSnapshotter(pool);

        (bool success, bytes memory data) = pool.call(dataIn);

        emit Response(pool, success, data);

        _poolsTable[name] = pool;

        Pool memory poolT = Pool(pool, name);
        Pools.push(poolT);

        emit PoolCreated(name, pool);
    }

    function Calling(string calldata name, bytes calldata dataIn)
        external
        onlyOwner
        shouldExist(name)
    {
        address dst = _poolsTable[name];
        (bool success, bytes memory data) = dst.call(dataIn);

        emit Response(dst, success, data);
    }

    function deposit(string calldata name, uint256 amount)
        external
        shouldExist(name)
    {
        // _usd.transferFrom(tx.origin, address(this), amount);
        // _usd.transfer(address(this), pool, amount);
        BranchOfPools(_poolsTable[name]).deposit(amount);
    }

    function paybackEmergency(string calldata name) external shouldExist(name) {
        BranchOfPools(_poolsTable[name]).paybackEmergency();
    }

    function claimName(string calldata name) external shouldExist(name) {
        BranchOfPools(_poolsTable[name]).claim();
    }

    function claimAddress(address pool) internal {
        require(pool != address(0), "ROOT: Selected pool does not exist!");

        BranchOfPools(pool).claim();
    }

    //TODO
    ///@dev To find out the list of pools from which a user can mine something,
    ///     use the prepClaimAll function
    function claimAll(address[] calldata pools) external {
        for (uint256 i; i < pools.length; i++) {
            claimAddress(pools[i]);
        }
    }

    /// @notice Returns the address of the usd token in which funds are collected
    function getUSDAddress() external view returns (address) {
        return _usdAddress;
    }

    /// @notice Returns the linked branch contracts
    function getPools() external view returns (Pool[] memory) {
        return Pools;
    }

    function getPool(string calldata _name) external view returns (address) {
        for (uint256 i = 0; i < Pools.length; i++) {
            if (
                keccak256(abi.encodePacked(Pools[i].name)) ==
                keccak256(abi.encodePacked(_name))
            ) {
                return Pools[i].pool;
            }
        }
        return address(0);
    }

    //TODO
    function prepClaimAll(address user)
        external
        view
        returns (address[] memory pools)
    {
        address[] memory out;
        for (uint256 i; i < Pools.length; i++) {
            if (BranchOfPools(Pools[i].pool).isClaimable(user)) {
                out[i] = Pools[i].pool;
            }
        }

        return pools;
    }

    function checkAllClaims(address user) external view returns (uint256) {
        uint256 temp;
        for (uint256 i; i < Pools.length; i++) {
            temp += (BranchOfPools(Pools[i].pool).myCurrentAllocation(user));
        }

        return temp;
    }
}
