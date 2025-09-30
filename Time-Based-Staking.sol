// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";

contract TimeBasedStaking is ReentrancyGuard {
    IERC20 public immutable stakingToken;
    IERC20 public immutable rewardToken;
    
    // Time-based parameters
    uint256 public constant REWARD_DURATION = 7 days;
    uint256 public periodFinish;
    uint256 public rewardRate;
    uint256 public lastUpdateTime;
    uint256 public rewardPerTokenStored;
    
    // Lock periods (in seconds)
    uint256[] public lockPeriods = [7 days, 30 days, 90 days];
    uint256[] public multipliers = [1e18, 12e17, 15e17]; // 1.0x, 1.2x, 1.5x
    
    // Staking tracking
    uint256 private _totalSupply;
    mapping(address => uint256) private _balances;
    
    // Time-based user data
    struct UserStake {
        uint256 amount;
        uint256 lockPeriod;
        uint256 stakeTime;
        uint256 unlockTime;
        uint256 multiplier;
    }
    
    mapping(address => UserStake[]) public userStakes;
    mapping(address => uint256) public userRewardPerTokenPaid;
    mapping(address => uint256) public rewards;
    
    event Staked(address indexed user, uint256 amount, uint256 lockPeriod, uint256 unlockTime);
    event Withdrawn(address indexed user, uint256 amount);
    event RewardPaid(address indexed user, uint256 reward);
    event RewardsAdded(uint256 reward, uint256 duration);

    constructor(address _stakingToken, address _rewardToken) {
        stakingToken = IERC20(_stakingToken);
        rewardToken = IERC20(_rewardToken);
        lastUpdateTime = block.timestamp;
        periodFinish = block.timestamp + REWARD_DURATION;
    }

    // ============ MODIFIERS ============
    
    modifier updateReward(address account) {
        rewardPerTokenStored = rewardPerToken();
        lastUpdateTime = lastTimeRewardApplicable();
        
        if (account != address(0)) {
            rewards[account] = earned(account);
            userRewardPerTokenPaid[account] = rewardPerTokenStored;
        }
        _;
    }
    
    modifier validLockPeriod(uint256 lockIndex) {
        require(lockIndex < lockPeriods.length, "Invalid lock period");
        _;
    }

    // ============ CORE FUNCTIONS ============
    
    function stake(uint256 amount, uint256 lockIndex) 
        external 
        nonReentrant 
        updateReward(msg.sender)
        validLockPeriod(lockIndex)
    {
        require(amount > 0, "Cannot stake 0");
        require(block.timestamp < periodFinish, "Staking period ended");
        
        uint256 lockPeriod = lockPeriods[lockIndex];
        uint256 multiplier = multipliers[lockIndex];
        uint256 unlockTime = block.timestamp + lockPeriod;
        
        // Update totals
        _totalSupply += amount;
        _balances[msg.sender] += amount;
        
        // Store user stake with time data
        userStakes[msg.sender].push(UserStake({
            amount: amount,
            lockPeriod: lockPeriod,
            stakeTime: block.timestamp,
            unlockTime: unlockTime,
            multiplier: multiplier
        }));
        
        // Transfer tokens
        bool success = stakingToken.transferFrom(msg.sender, address(this), amount);
        require(success, "Transfer failed");
        
        emit Staked(msg.sender, amount, lockPeriod, unlockTime);
    }
    
    function withdraw(uint256 stakeIndex) public nonReentrant updateReward(msg.sender) {
        require(stakeIndex < userStakes[msg.sender].length, "Invalid stake index");
        
        UserStake memory userStake = userStakes[msg.sender][stakeIndex];
        require(block.timestamp >= userStake.unlockTime, "Stake still locked");
        
        uint256 amount = userStake.amount;
        
        // Remove stake from array
        _removeStake(msg.sender, stakeIndex);
        
        // Update totals
        _totalSupply -= amount;
        _balances[msg.sender] -= amount;

        // Transfer back to user
        bool success = stakingToken.transfer(msg.sender, amount);
        require(success, "Transfer failed");
        
        emit Withdrawn(msg.sender, amount);
    }

    function getReward() public nonReentrant updateReward(msg.sender) {
        uint256 reward = rewards[msg.sender];
        if (reward > 0) {
            rewards[msg.sender] = 0;
            
            uint256 contractBalance = rewardToken.balanceOf(address(this));
            require(contractBalance >= reward, "Insufficient reward tokens");
            
            bool success = rewardToken.transfer(msg.sender, reward);
            require(success, "Reward transfer failed");
            
            emit RewardPaid(msg.sender, reward);
        }
    }

    function exit(uint256 stakeIndex) external {
        withdraw(stakeIndex);
        getReward();
    }

    // ============ REWARD MANAGEMENT ============

    function notifyRewardAmount(uint256 reward) external updateReward(address(0)) {
        require(reward > 0, "No reward");
        
        if (block.timestamp >= periodFinish) {
            rewardRate = reward / REWARD_DURATION;
        } else {
            uint256 remaining = periodFinish - block.timestamp;
            uint256 leftover = remaining * rewardRate;
            rewardRate = (reward + leftover) / REWARD_DURATION;
        }

        uint256 balance = rewardToken.balanceOf(address(this));
        require(rewardRate <= balance / REWARD_DURATION, "Provided reward too high");

        lastUpdateTime = block.timestamp;
        periodFinish = block.timestamp + REWARD_DURATION;
        emit RewardsAdded(reward, REWARD_DURATION);
    }

    // ============ TIME-BASED CALCULATIONS ============

    function rewardPerToken() public view returns (uint256) {
        if (_totalSupply == 0) {
            return rewardPerTokenStored;
        }
        return rewardPerTokenStored + 
            (((lastTimeRewardApplicable() - lastUpdateTime) * rewardRate * 1e18) / _totalSupply);
    }

    function earned(address account) public view returns (uint256) {
        uint256 userMultiplier = getUserMultiplier(account);
        return ((_balances[account] * 
                (rewardPerToken() - userRewardPerTokenPaid[account]) * userMultiplier) / 1e36) 
                + rewards[account];
    }

    function lastTimeRewardApplicable() public view returns (uint256) {
        return block.timestamp < periodFinish ? block.timestamp : periodFinish;
    }

    function getUserMultiplier(address account) public view returns (uint256) {
        if (userStakes[account].length == 0) return 1e18;
        
        uint256 totalWeightedMultiplier = 0;
        uint256 totalStaked = 0;
        
        for (uint i = 0; i < userStakes[account].length; i++) {
            UserStake memory stake = userStakes[account][i];
            totalWeightedMultiplier += stake.amount * stake.multiplier;
            totalStaked += stake.amount;
        }
        
        return totalStaked > 0 ? totalWeightedMultiplier / totalStaked : 1e18;
    }

    // ============ VIEW FUNCTIONS ============

    function totalSupply() external view returns (uint256) {
        return _totalSupply;
    }

    function balanceOf(address account) external view returns (uint256) {
        return _balances[account];
    }

    function getStakeCount(address account) external view returns (uint256) {
        return userStakes[account].length;
    }

    function getStakeDetails(address account, uint256 index) external view returns (
        uint256 amount,
        uint256 lockPeriod,
        uint256 stakeTime,
        uint256 unlockTime,
        uint256 multiplier
    ) {
        UserStake memory stake = userStakes[account][index];
        return (stake.amount, stake.lockPeriod, stake.stakeTime, stake.unlockTime, stake.multiplier);
    }

    function getTimeUntilUnlock(address account, uint256 index) external view returns (uint256) {
        UserStake memory stake = userStakes[account][index];
        if (block.timestamp >= stake.unlockTime) return 0;
        return stake.unlockTime - block.timestamp;
    }

    function isStakeLocked(address account, uint256 index) external view returns (bool) {
        UserStake memory stake = userStakes[account][index];
        return block.timestamp < stake.unlockTime;
    }

    // ============ INTERNAL FUNCTIONS ============

    function _removeStake(address account, uint256 index) internal {
        uint256 lastIndex = userStakes[account].length - 1;
        if (index != lastIndex) {
            userStakes[account][index] = userStakes[account][lastIndex];
        }
        userStakes[account].pop();
    }
}
