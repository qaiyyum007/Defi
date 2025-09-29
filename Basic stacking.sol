// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract BasicStaking {
    // State Variables
    IERC20 public stakingToken;
    IERC20 public rewardToken;
    
    // Staking tracking
    uint256 public totalStaked;
    mapping(address => uint256) public stakedBalance;
    
    // Reward tracking
   // Fixed reward rate (1 token/second, using 18 decimals)
   // Last time rewards were updated
   // Accumulated rewards per token stored
   // Mapping to track each user's last reward checkpoint

Mapping to track pending rewards for each user
    uint256 public rewardRate = 1e18; // 1 token per second
    uint256 public lastUpdateTime;
    uint256 public rewardPerTokenStored;
    
    mapping(address => uint256) public userRewardPerTokenPaid;
    mapping(address => uint256) public rewards;
    
    // Events
    event Staked(address indexed user, uint256 amount);
    event Withdrawn(address indexed user, uint256 amount);
    event RewardPaid(address indexed user, uint256 reward);
    
    constructor(address _stakingToken, address _rewardToken) {
        stakingToken = IERC20(_stakingToken);
        rewardToken = IERC20(_rewardToken);
        lastUpdateTime = block.timestamp;
    }
    
    // MODIFIER: Update rewards before important actions
    modifier updateReward(address account) {
        rewardPerTokenStored = rewardPerToken();
        lastUpdateTime = block.timestamp;
        
        if (account != address(0)) {
            rewards[account] = earned(account);
            userRewardPerTokenPaid[account] = rewardPerTokenStored;
        }
        _;
    }
    
    // REWARD CALCULATION: How much reward per staked token

    // Updates global reward accumulation
    // Updates individual user rewards before state-changing operations
    // Handles zero address for cases where no specific account update is needed
    // rewardPerToken = how many rewards each staked token has earned in total so far.
    // userRewardPerTokenPaid[account] = how many rewards per token this user has already been credited for.


    function rewardPerToken() public view returns (uint256) {
        if (totalStaked == 0) {
            return rewardPerTokenStored;
        }
        return rewardPerTokenStored + 
            ((block.timestamp - lastUpdateTime) * rewardRate * 1e18) / totalStaked;
    }
    
    // EARNED: Calculate how much reward user has earned
    function earned(address account) public view returns (uint256) {
        return ((stakedBalance[account] * 
                (rewardPerToken() - userRewardPerTokenPaid[account])) / 1e18) 
                + rewards[account];
    }
    
    // STAKE: Deposit tokens to start earning rewards
    function stake(uint256 amount) external updateReward(msg.sender) {
        require(amount > 0, "Cannot stake 0");
        
        totalStaked += amount;
        stakedBalance[msg.sender] += amount;
        
        bool success = stakingToken.transferFrom(msg.sender, address(this), amount);
        require(success, "Transfer failed");
        
        emit Staked(msg.sender, amount);
    }
    
    // WITHDRAW: Remove staked tokens
    function withdraw(uint256 amount) public updateReward(msg.sender) {
        require(amount > 0, "Cannot withdraw 0");
        require(stakedBalance[msg.sender] >= amount, "Insufficient balance");
        
        totalStaked -= amount;
        stakedBalance[msg.sender] -= amount;
        
        bool success = stakingToken.transfer(msg.sender, amount);
        require(success, "Transfer failed");
        
        emit Withdrawn(msg.sender, amount);
    }
    
    // GET REWARD: Claim earned rewards
    function getReward() public updateReward(msg.sender) {
        uint256 reward = rewards[msg.sender];
        if (reward > 0) {
            rewards[msg.sender] = 0;
            bool success = rewardToken.transfer(msg.sender, reward);
            require(success, "Reward transfer failed");
            emit RewardPaid(msg.sender, reward);
        }
    }
    
    // EXIT: Withdraw all and claim rewards
    function exit() external {
        withdraw(stakedBalance[msg.sender]);
        getReward();
    }
}
