// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @title Multi-Reward Staking Contract
 * @dev Allows users to stake tokens and earn multiple reward tokens simultaneously
 * with separate tracking and distribution mechanisms for each reward token.
 */
contract MultiRewardStaking is ReentrancyGuard, Ownable {
    using SafeERC20 for IERC20;

    // ============ STRUCTS ============

    struct RewardTokenInfo {
        IERC20 token;
        uint256 rewardRate; // Rewards per second per staked token
        uint256 rewardPerTokenStored;
        uint256 lastUpdateTime;
        uint256 periodFinish;
        uint256 totalRewards;
    }

    struct UserInfo {
        uint256 balance;
        mapping(address => uint256) userRewardPerTokenPaid;
        mapping(address => uint256) rewards;
    }

    // ============ STATE VARIABLES ============

    IERC20 public stakingToken;
    
    // Reward token tracking
    address[] public rewardTokens;
    mapping(address => RewardTokenInfo) public rewardTokenInfo;
    mapping(address => bool) public isRewardToken;
    
    // User tracking
    mapping(address => UserInfo) private _userInfo;
    
    // Staking metrics
    uint256 private _totalSupply;
    uint256 public constant REWARD_DURATION = 7 days;

    // ============ EVENTS ============

    event Staked(address indexed user, uint256 amount);
    event Withdrawn(address indexed user, uint256 amount);
    event RewardAdded(address indexed rewardToken, uint256 reward);
    event RewardPaid(address indexed user, address indexed rewardToken, uint256 reward);
    event RewardTokenAdded(address indexed rewardToken);
    event RewardTokenRemoved(address indexed rewardToken);

    // ============ MODIFIERS ============

    modifier updateReward(address account) {
        _updateAllRewards(account);
        _;
    }

    modifier validRewardToken(address rewardToken) {
        require(isRewardToken[rewardToken], "Invalid reward token");
        _;
    }

    // ============ CONSTRUCTOR ============

    constructor(address _stakingToken) {
        stakingToken = IERC20(_stakingToken);
    }

    // ============ EXTERNAL FUNCTIONS ============

    /**
     * @dev Stake tokens to earn multiple rewards
     */
    function stake(uint256 amount) external nonReentrant updateReward(msg.sender) {
        require(amount > 0, "Cannot stake 0");
        
        _totalSupply += amount;
        _userInfo[msg.sender].balance += amount;
        
        stakingToken.safeTransferFrom(msg.sender, address(this), amount);
        emit Staked(msg.sender, amount);
    }

    /**
     * @dev Withdraw staked tokens
     */
    function withdraw(uint256 amount) public nonReentrant updateReward(msg.sender) {
        require(amount > 0, "Cannot withdraw 0");
        
        _totalSupply -= amount;
        _userInfo[msg.sender].balance -= amount;
        
        stakingToken.safeTransfer(msg.sender, amount);
        emit Withdrawn(msg.sender, amount);
    }

    /**
     * @dev Claim all pending rewards for all reward tokens
     */
    function getReward() external nonReentrant updateReward(msg.sender) {
        for (uint i = 0; i < rewardTokens.length; i++) {
            address rewardToken = rewardTokens[i];
            _getReward(msg.sender, rewardToken);
        }
    }

    /**
     * @dev Claim specific reward token
     */
    function getRewardForToken(address rewardToken) 
        external 
        nonReentrant 
        updateReward(msg.sender)
        validRewardToken(rewardToken)
    {
        _getReward(msg.sender, rewardToken);
    }

    /**
     * @dev Exit staking - withdraw all and claim all rewards
     */
    function exit() external {
        withdraw(_userInfo[msg.sender].balance);
        getReward();
    }

    // ============ ADMIN FUNCTIONS ============

    /**
     * @dev Add a new reward token to the staking contract
     */
    function addRewardToken(address rewardToken) external onlyOwner {
        require(!isRewardToken[rewardToken], "Reward token already added");
        require(rewardToken != address(stakingToken), "Cannot add staking token as reward");
        
        rewardTokens.push(rewardToken);
        isRewardToken[rewardToken] = true;
        rewardTokenInfo[rewardToken].token = IERC20(rewardToken);
        
        emit RewardTokenAdded(rewardToken);
    }

    /**
     * @dev Remove a reward token (emergency use only)
     */
    function removeRewardToken(address rewardToken) external onlyOwner validRewardToken(rewardToken) {
        isRewardToken[rewardToken] = false;
        
        // Remove from rewardTokens array
        for (uint i = 0; i < rewardTokens.length; i++) {
            if (rewardTokens[i] == rewardToken) {
                rewardTokens[i] = rewardTokens[rewardTokens.length - 1];
                rewardTokens.pop();
                break;
            }
        }
        
        emit RewardTokenRemoved(rewardToken);
    }

    /**
     * @dev Notify reward amount for a specific reward token
     */
    function notifyRewardAmount(address rewardToken, uint256 reward) 
        external 
        onlyOwner 
        validRewardToken(rewardToken)
        updateReward(address(0))
    {
        RewardTokenInfo storage rewardInfo = rewardTokenInfo[rewardToken];
        
        if (block.timestamp >= rewardInfo.periodFinish) {
            rewardInfo.rewardRate = reward / REWARD_DURATION;
        } else {
            uint256 remaining = rewardInfo.periodFinish - block.timestamp;
            uint256 leftover = remaining * rewardInfo.rewardRate;
            rewardInfo.rewardRate = (reward + leftover) / REWARD_DURATION;
        }

        rewardInfo.lastUpdateTime = block.timestamp;
        rewardInfo.periodFinish = block.timestamp + REWARD_DURATION;
        rewardInfo.totalRewards += reward;

        IERC20(rewardToken).safeTransferFrom(msg.sender, address(this), reward);
        emit RewardAdded(rewardToken, reward);
    }

    // ============ VIEW FUNCTIONS ============

    /**
     * @dev Get total staked amount
     */
    function totalSupply() external view returns (uint256) {
        return _totalSupply;
    }

    /**
     * @dev Get user's staked amount
     */
    function balanceOf(address account) external view returns (uint256) {
        return _userInfo[account].balance;
    }

    /**
     * @dev Get list of all reward tokens
     */
    function getRewardTokens() external view returns (address[] memory) {
        return rewardTokens;
    }

    /**
     * @dev Get earned rewards for a specific token for a user
     */
    function earned(address account, address rewardToken) 
        public 
        view 
        validRewardToken(rewardToken)
        returns (uint256) 
    {
        UserInfo storage user = _userInfo[account];
        RewardTokenInfo storage rewardInfo = rewardTokenInfo[rewardToken];
        
        uint256 userBalance = user.balance;
        uint256 rewardPerTokenStored = rewardPerToken(rewardToken);
        
        return (
            (userBalance * (rewardPerTokenStored - user.userRewardPerTokenPaid[rewardToken])) / 1e18
        ) + user.rewards[rewardToken];
    }

    /**
     * @dev Get earned rewards for all tokens for a user
     */
    function earnedAll(address account) 
        external 
        view 
        returns (address[] memory tokens, uint256[] memory amounts) 
    {
        tokens = rewardTokens;
        amounts = new uint256[](tokens.length);
        
        for (uint i = 0; i < tokens.length; i++) {
            amounts[i] = earned(account, tokens[i]);
        }
    }

    /**
     * @dev Calculate current reward per token for a specific reward token
     */
    function rewardPerToken(address rewardToken) 
        public 
        view 
        validRewardToken(rewardToken)
        returns (uint256) 
    {
        RewardTokenInfo storage rewardInfo = rewardTokenInfo[rewardToken];
        
        if (_totalSupply == 0) {
            return rewardInfo.rewardPerTokenStored;
        }
        
        uint256 timeSinceLastUpdate = lastTimeRewardApplicable(rewardToken) - rewardInfo.lastUpdateTime;
        return rewardInfo.rewardPerTokenStored + (
            (timeSinceLastUpdate * rewardInfo.rewardRate * 1e18) / _totalSupply
        );
    }

    /**
     * @dev Get last time reward was applicable
     */
    function lastTimeRewardApplicable(address rewardToken) 
        public 
        view 
        validRewardToken(rewardToken)
        returns (uint256) 
    {
        RewardTokenInfo storage rewardInfo = rewardTokenInfo[rewardToken];
        return block.timestamp < rewardInfo.periodFinish ? block.timestamp : rewardInfo.periodFinish;
    }

    // ============ INTERNAL FUNCTIONS ============

    function _updateAllRewards(address account) internal {
        for (uint i = 0; i < rewardTokens.length; i++) {
            address rewardToken = rewardTokens[i];
            _updateReward(account, rewardToken);
        }
    }

    function _updateReward(address account, address rewardToken) internal {
        RewardTokenInfo storage rewardInfo = rewardTokenInfo[rewardToken];
        rewardInfo.rewardPerTokenStored = rewardPerToken(rewardToken);
        rewardInfo.lastUpdateTime = lastTimeRewardApplicable(rewardToken);
        
        if (account != address(0)) {
            UserInfo storage user = _userInfo[account];
            user.rewards[rewardToken] = earned(account, rewardToken);
            user.userRewardPerTokenPaid[rewardToken] = rewardInfo.rewardPerTokenStored;
        }
    }

    function _getReward(address account, address rewardToken) internal {
        uint256 reward = _userInfo[account].rewards[rewardToken];
        if (reward > 0) {
            _userInfo[account].rewards[rewardToken] = 0;
            IERC20(rewardToken).safeTransfer(account, reward);
            emit RewardPaid(account, rewardToken, reward);
        }
    }
}
