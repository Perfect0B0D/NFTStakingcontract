// SPDX-License-Identifier: MIT
pragma solidity ^0.8.7;
import "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import '@openzeppelin/contracts/utils/math/Math.sol';
import '@openzeppelin/contracts/security/ReentrancyGuard.sol';
import 'hardhat/console.sol';

/**
 * @title StakePool
 * @notice Represents a contract where a token owner has put her tokens up for others to stake and earn said tokens.
 */

interface IObelisk {
    function getRewardNum(address add) external view returns(uint256);
    function getDailyRewardOfUser(address add) external view returns(uint256);
    function stakeGenesis(address _account) external;
    function unStakeGenesis(address _account) external;
    function harvest(address _account) external;
}

interface ILand {
    function getRewardNum(address add) external view returns(uint256);
    function getDailyRewardOfUser(address add) external view returns(uint256);
    function stakeGenesis(address _account) external;
    function unStakeGenesis(address _account) external;
    function harvest(address _account) external;
}

interface IImmortalStakedToken {
  function getRevealTime() external view returns (uint256);
  function getType(bytes32[] calldata _merkleProof,  uint256 _id) external view returns(uint256);
}



contract StakeToken is ERC20, Ownable, ReentrancyGuard {
  bool public contractIsRemoved = false;

  IERC20 private _rewardsToken;
  address private _immortalStakedToken;

  IObelisk private _obelisk;
  ILand private _land;

  // uint256 private oneDay = 1 days;
  uint256 private oneDay = 10 minutes;

  PoolInfo public pool;
  address private constant _burner = 0x000000000000000000000000000000000000dEaD;
  struct PoolInfo {
    address creator; // address of contract creator
    address tokenOwner; // address of original rewards token owner
    uint256 origTotSupply; // supply of rewards tokens put up to be rewarded by original owner
    uint256 curRewardsSupply; // current supply of rewards
    uint256 creationBlock; // block this contract was created
    uint256 totalTokensStaked; // current amount of tokens staked
    uint256 stakeTimeLockSec; // number of seconds after depositing the user is required to stake before unstaking
    uint256[8] alloc; // the reward amount per day for common NFT, rare NFT, queenNFT, hyperNFT
    uint256[8] totalKindNFT; // the total amount of common nft, rare NFT, queenNFT, hyperNFT
  }

  struct StakerInfo {
    uint256 blockOriginallyStaked; // block the user originally staked
    uint256 timeOriginallyStaked; // unix timestamp in seconds that the user originally staked
    uint256 blockLastHarvested; // the block the user last claimed/harvested rewards
    uint256[8] kindNFT; // the common NFT count, rare NFT, queen NFT, hyper NFT
    uint256[] nftTokenIds; // if this is an NFT staking pool, make sure we store the token IDs here
  }

  //number of stakers
 //e uint256 public totalStakers;

  // mapping of userAddresses => tokenAddresses that can
  // can be evaluated to determine for a particular user which tokens
  // they are staking.
  mapping(address => StakerInfo) public stakers;
  
  // mapping of userAddresses => total reward paid amount
  mapping(address => uint256) public totalRewardPaid;

  event Deposit(address indexed user, uint256 amount);
  event Withdraw(address indexed user, uint256 amount);

  /**
   * @notice The constructor for the Staking Token.
   */
  constructor( address _rewardsTokenAddr, address _immortalStakedTokenAddr, address _originalTokenOwner, 
        address _landAddr, address _obeliskAddr
        ) ERC20("stakingToken", "STT") {

    uint256 _rewardSupply;
    uint256[8] memory _alloc;
    uint256 _stakeTimeLockSec;
    _rewardSupply = 10000000000 * 10 ** 18;
    // _originalTokenOwner = 0x5B38Da6a701c568545dCfcB03FcB875f56beddC4;
    _alloc = [uint256(40 ether), 45 ether, 50 ether,
                  55 ether, 70 ether, 80 ether,
                  100 ether, 120 ether];
    _stakeTimeLockSec = 0;
    _rewardsToken = IERC20(_rewardsTokenAddr);
    _immortalStakedToken = _immortalStakedTokenAddr;
    _obelisk = IObelisk(_obeliskAddr);
    _land = ILand(_landAddr);

    pool = PoolInfo({
      creator: msg.sender,
      tokenOwner: _originalTokenOwner,
      origTotSupply: _rewardSupply,
      curRewardsSupply: _rewardSupply,
      creationBlock: 0,
      totalTokensStaked: 0,
      stakeTimeLockSec: _stakeTimeLockSec,
      alloc: _alloc,
      totalKindNFT: [uint256(0),0,0,0,0,0,0,0]
    });
  }
  
  // SHOULD ONLY BE CALLED AT CONTRACT CREATION and allows changing
  // the initial supply if tokenomics of token transfer causes
  // the original staking contract supply to be less than the original
  function updateSupply(uint256 _newSupply) external {
    require( msg.sender == pool.creator, 'only contract creator can update the supply');
    pool.origTotSupply = _newSupply;
    pool.curRewardsSupply = _newSupply;
    _rewardsToken.transferFrom(msg.sender, address(this), _newSupply);
  }
  function stakedTokenAddress() external view returns (address) {
    return address(_immortalStakedToken);
  }

  function rewardsTokenAddress() external view returns (address) {
    return address(_rewardsToken);
  }

  function tokenOwner() external view returns (address) {
    return pool.tokenOwner;
  }

  function getStakedTokenIds(address userAddress) external view returns(uint256[] memory) {
    uint len =  stakers[userAddress].nftTokenIds.length;
    uint256[] memory ret = new uint256[](len);
    for (uint i = 0; i < len; i++) {
        ret[i] = stakers[userAddress].nftTokenIds[i];
    }
    return ret;
  }

  function removeStakeableTokens() external {
    require(
      msg.sender == pool.creator || msg.sender == pool.tokenOwner,
      'caller must be the contract creator or owner to remove stakable tokens'
    );
    _rewardsToken.transfer(pool.tokenOwner, pool.curRewardsSupply);
    pool.curRewardsSupply = 0;
    contractIsRemoved = true;
  }

  function stakeTokens(uint256[] memory _tokenIds, bytes32[][] memory _merkleProofs) public  {
    require( getLastStakableBlock(), 'no more stakers can be added');
    require(_tokenIds.length > 0, "you need to provide NFT token IDs you're staking");
    require(IImmortalStakedToken(_immortalStakedToken).getRevealTime() > 0, 'Immortals not yet revealed');

    uint256 _finalAmountTransferred;
    // if first stake, establish creation block
   //e if (totalSupply() == 0) {
  //e    pool.creationBlock = block.number;
  //e  }
    //e if (balanceOf(msg.sender) > 0) {
    //e  _harvestTokens(msg.sender);
   //e }

    StakerInfo storage _staker = stakers[msg.sender];
    _staker.blockOriginallyStaked = block.number;
    _staker.timeOriginallyStaked = block.timestamp;
    _staker.blockLastHarvested = block.number;
    
    // stake each genesis
    for (uint256 _i = 0; _i < _tokenIds.length; _i++) {
      IERC721(_immortalStakedToken).transferFrom(msg.sender, address(this), _tokenIds[_i]);
      uint256 _type = IImmortalStakedToken(_immortalStakedToken).getType(_merkleProofs[_i], _tokenIds[_i]);
      require(_type <= 7, "Genesis Bad Type");
      _staker.nftTokenIds.push(_tokenIds[_i]);
      _staker.kindNFT[_type] = _staker.kindNFT[_type] + 1;
      pool.totalKindNFT[_type] = pool.totalKindNFT[_type] + 1;
    }

    _finalAmountTransferred = _tokenIds.length * 10 ** 18;

  //e  if(balanceOf(msg.sender) == 0) {
  //e    totalStakers++;
  //e  }

    _mint(msg.sender, _finalAmountTransferred);
    _updNumStaked(_finalAmountTransferred, 1);
    // store staking for obleisk/land to access
    _obelisk.stakeGenesis(msg.sender);
    _land.stakeGenesis(msg.sender);
    //e emit Deposit(msg.sender, _finalAmountTransferred);
  }

  // pass 'false' for _shouldHarvest for emergency unstaking without claiming rewards
  function unstakeTokens(bool _shouldHarvest) external nonReentrant {
    StakerInfo memory _staker = stakers[msg.sender];
    uint256 _userBalance = balanceOf(msg.sender);

    // allow unstaking if the user is emergency unstaking and not getting rewards or
    // if theres a time lock that it's past the time lock or
    // the contract rewards were removed by the original contract creator or
    // the contract is expired
    require(
      !_shouldHarvest ||
        block.timestamp >=
        _staker.timeOriginallyStaked + pool.stakeTimeLockSec ||
        contractIsRemoved ||
        getLastStakableBlock(),
      'you have not staked for minimum time lock yet and the pool is not expired'
    );

    if (_shouldHarvest) {
      _harvestTokens(msg.sender);
    }

    uint256 _amountToRemoveFromStaked = _userBalance;

    transfer(_burner, _amountToRemoveFromStaked);

    for (uint256 _i = 0; _i < _staker.nftTokenIds.length; _i++) {
        IERC721(_immortalStakedToken).transferFrom(
            address(this),
            msg.sender,
            _staker.nftTokenIds[_i]
        );
    }

    for(uint256 i = 0; i < 8; i++) {
      pool.totalKindNFT[i] = pool.totalKindNFT[i] - _staker.kindNFT[i];
    }

    if (balanceOf(msg.sender) <= 0) {
      delete stakers[msg.sender];
 //e     if (totalStakers > 0) {
  //e      totalStakers--;
 //e     }
    }

    _updNumStaked(_amountToRemoveFromStaked, 0);
    
    _obelisk.unStakeGenesis(msg.sender);
    _land.unStakeGenesis(msg.sender);

    emit Withdraw(msg.sender, _amountToRemoveFromStaked);
  }

  // pass 'false' for _shouldHarvest for emergency unstaking without claiming rewards
  function unstakeTokensById(bool _shouldHarvest, bytes32[][] memory _merkleProofs,  uint256[] memory _tokenIds) external nonReentrant {
    StakerInfo storage _staker = stakers[msg.sender];

    // allow unstaking if the user is emergency unstaking and not getting rewards or
    // if theres a time lock that it's past the time lock or
    // the contract rewards were removed by the original contract creator or
    // the contract is expired
    require(
      !_shouldHarvest ||
        block.timestamp >=
        _staker.timeOriginallyStaked + pool.stakeTimeLockSec ||
        contractIsRemoved ||
        getLastStakableBlock(),
      'you have not staked for minimum time lock yet and the pool is not expired'
    );

    if (_shouldHarvest) {
      _harvestTokens(msg.sender);
    }

    // uint256 _amountToRemoveFromStaked = _userBalance;
    uint256 _amountToRemoveFromStaked = _tokenIds.length * 10**18;

    transfer(_burner, _amountToRemoveFromStaked);

    for (uint256 _i = 0; _i < _tokenIds.length; _i++) {
        IERC721(_immortalStakedToken).transferFrom(
            address(this),
            msg.sender,
           _tokenIds[_i]
        );
    }

    for(uint256 i = 0; i < _tokenIds.length; i++) {
      uint256 _type = IImmortalStakedToken(_immortalStakedToken).getType(_merkleProofs[i], _tokenIds[i]);
      _staker.kindNFT[_type] = _staker.kindNFT[_type] - 1;
      pool.totalKindNFT[_type] = pool.totalKindNFT[_type] - 1;
    }

    if (balanceOf(msg.sender) <= 0) {
      delete stakers[msg.sender];
      //e if (totalStakers > 0) {
      //e  totalStakers--;
      //e }
    } else {
      for(uint256 i = 0; i < _tokenIds.length; i++) {
        uint256 index = 8889;
        for(uint256 j = 0; j < _staker.nftTokenIds.length; j++) {
          if(_tokenIds[i] == _staker.nftTokenIds[j]) {
            index = j;
            break;              
          }
        }
        if(index != 8889) {
          for (uint256 k = index; k < _staker.nftTokenIds.length - 1; k++) {
              _staker.nftTokenIds[k] = _staker.nftTokenIds[k+1];
          }
          _staker.nftTokenIds.pop(); // delete the last item           
        }
      }
    }

    _updNumStaked(_amountToRemoveFromStaked, 0);

    if(balanceOf(msg.sender) == 0) {
      _obelisk.unStakeGenesis(msg.sender);
      _land.unStakeGenesis(msg.sender);
    } else {
      _obelisk.harvest(msg.sender);
      _land.harvest(msg.sender);
    }

    emit Withdraw(msg.sender, _amountToRemoveFromStaked);
  }

  function claimRewards()
    external
    nonReentrant
    returns (uint256)
  {
      require(
        block.timestamp >= stakers[msg.sender].timeOriginallyStaked + pool.stakeTimeLockSec ||
        contractIsRemoved ||
        getLastStakableBlock(),
      'you have not staked for minimum time lock yet and the pool is not expired'
    );
    uint256 _tokensToUser = _harvestTokens(msg.sender);
    return _tokensToUser;
  }

  function emergencyUnstake() external nonReentrant{
    StakerInfo memory _staker = stakers[msg.sender];
    uint256 _amountToRemoveFromStaked = balanceOf(msg.sender);
    require(
      _amountToRemoveFromStaked > 0,
      'user can only unstake if they have tokens in the pool'
    );

    transfer(_burner, _amountToRemoveFromStaked);

    for (uint256 _i = 0; _i < _staker.nftTokenIds.length; _i++) {
        IERC721(_immortalStakedToken).transferFrom(
            address(this),
            msg.sender,
            _staker.nftTokenIds[_i]
        );
    }
    
    for(uint256 i = 0; i < 8; i++) {
      pool.totalKindNFT[i] = pool.totalKindNFT[i] - _staker.kindNFT[i];
    }

    delete stakers[msg.sender];

 //e   if (totalStakers > 0) {
 //e     totalStakers--;
  //e  }

    _updNumStaked(_amountToRemoveFromStaked, 0);

    emit Withdraw(msg.sender, _amountToRemoveFromStaked);
  }

  function harvestForUser(address _userAddr)
    external
    nonReentrant
    returns (uint256)
  {
    require(
      msg.sender == pool.creator || msg.sender == _userAddr,
      'can only harvest tokens for someone else if this was the contract creator'
    );

    uint256 _tokensToUser = _harvestTokens(_userAddr);

    return _tokensToUser;
  }

  function getTotalRewardPaid(address _userAddr) external view returns (uint256) {
    return totalRewardPaid[_userAddr];
  }


//e  function getTotalStakers() external view returns (uint256) {
//e    return totalStakers;
//e  }

  function getLastStakableBlock() public view returns (bool) {
    uint256 _rewardAmount = 0;
    for(uint256 i = 0; i < 8; i++) {
      uint256 _rewardItemAmount = pool.alloc[i] * pool.totalKindNFT[i] * 1e36;
      _rewardItemAmount = _rewardItemAmount / oneDay;
      _rewardAmount = _rewardAmount + _rewardItemAmount;
    }

    _rewardAmount = _rewardAmount / 1e36;

    if(pool.curRewardsSupply > _rewardAmount)
      return true;
    else
      return false;
  }

  function calcHarvestNumFormOther(address _userAddr) public view returns(uint256) {
    return _obelisk.getRewardNum(_userAddr) + _land.getRewardNum(_userAddr);
  }

  // Get Daily Rewards
  function getDailyRewards(address _userAddr) public view returns (uint256){
    StakerInfo memory _staker = stakers[_userAddr];
    uint256 _dailyRewardAmount = 0;
    uint256 _dailyObelisk = _obelisk.getDailyRewardOfUser(_userAddr);
    uint256 _dailyLand = _land.getDailyRewardOfUser(_userAddr);
    for(uint256 i = 0; i < 8; i++) {
      uint256 _rewardItemAmount = pool.alloc[i] * _staker.kindNFT[i];
      _dailyRewardAmount = _dailyRewardAmount + _rewardItemAmount;
    }
    return _dailyRewardAmount + _dailyObelisk + _dailyLand;
  }

  function calcHarvestTot(address _userAddr) public view returns (uint256)  {
    StakerInfo memory _staker = stakers[_userAddr];
    uint256 revealTime = IImmortalStakedToken(_immortalStakedToken).getRevealTime();

    if (_staker.blockLastHarvested >= block.number ||
      _staker.blockOriginallyStaked == 0 ||
      pool.totalTokensStaked == 0 ||
      !getLastStakableBlock()
    ) {
      return uint256(0);
    }

    uint256 _nrOfBlocks = block.timestamp - _staker.timeOriginallyStaked;
    if (_staker.timeOriginallyStaked <= revealTime + oneDay * 3) {      
      _nrOfBlocks = _nrOfBlocks + Math.min(block.timestamp, revealTime + oneDay * 3) - _staker.timeOriginallyStaked;
    }

    uint256 _rewardAmount = 0;
    for(uint256 i = 0; i < 8; i++) {
      // uint256 _rewardItemAmount = pool.alloc[i] * pool.totalKindNFT[i] * 1e36;
      uint256 _rewardItemAmount = pool.alloc[i] * _staker.kindNFT[i] * _nrOfBlocks * 1e36;
      _rewardItemAmount = _rewardItemAmount / oneDay;
      _rewardAmount = _rewardAmount + _rewardItemAmount;
    }

    _rewardAmount = _rewardAmount / 1e36;

    uint256 _rewardFormOther = calcHarvestNumFormOther(_userAddr);
    _rewardAmount = _rewardAmount + _rewardFormOther;
    return _rewardAmount;
  }

  function _harvestTokens(address _userAddr) private returns (uint256) {
    StakerInfo storage _staker = stakers[_userAddr];
    //require(_staker.blockOriginallyStaked > 0, 'user must have tokens staked');

    uint256 _num2Trans = calcHarvestTot(_userAddr);
    require(pool.curRewardsSupply >= _num2Trans, "P2E Staking: harvest would exceed remaining pool");
    if (_num2Trans > 0) {
      require(
        _rewardsToken.transfer(_userAddr, _num2Trans),
        'unable to send user their harvested tokens'
      );
      pool.curRewardsSupply = pool.curRewardsSupply - _num2Trans;
    }
 
    // _obelisk.clearHoldingAllInfo(_userAddr);
    // _land.clearHoldingAllInfo(_userAddr);

    _staker.blockLastHarvested = block.number;
    _staker.timeOriginallyStaked = block.timestamp;

    totalRewardPaid[_userAddr] = totalRewardPaid[_userAddr] + _num2Trans;

    return _num2Trans;
  }

  // update the amount currently staked after a user harvests. 0: remove, 1: add
  function _updNumStaked(uint256 _amount, uint256 _operation) private {
    if (_operation == 0) {
      pool.totalTokensStaked = pool.totalTokensStaked - _amount;
    } else {
      pool.totalTokensStaked = pool.totalTokensStaked + _amount;
    }
  }

}