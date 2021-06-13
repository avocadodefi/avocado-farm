// SPDX-License-Identifier: MIT

pragma solidity ^0.6.12;

import "@openzeppelin/contracts/math/SafeMath.sol";
import "./libs/IBEP20.sol";
import "./libs/SafeBEP20.sol";
import "./libs/IAvocadoReferral.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import "./AvocadoToken.sol";

// MasterChef is the master of Avocado. He can make Avocado and he is a fair guy.
//
// Note that it's ownable and the owner wields tremendous power. The ownership
// will be transferred to a governance smart contract once Avocado is sufficiently
// distributed and the community can show to govern itself.
//
// Have fun reading it. Hopefully it's bug-free. God bless.
contract MasterChef is Ownable, ReentrancyGuard {
    using SafeMath for uint256;
    using SafeBEP20 for IBEP20;

    // Info of each user.
    struct UserInfo {
        uint256 amount;         // How many LP tokens the user has provided.
        uint256 rewardDebt;     // Reward debt. See explanation below.
        uint256 rewardLockedUp;  // Reward locked up.
        uint256 nextHarvestUntil; // When can the user harvest again.
        bool bonusTimerStarted;  // indicates user is qualified for bonus timekeeping
        uint256 timerStartedAt;  // timestamp when bonus timekeeping started for this user
        uint16 bonusMultiplier;
        //
        // We do some fancy math here. Basically, any point in time, the amount of Avocados
        // entitled to a user but is pending to be distributed is:
        //
        //   pending reward = (user.amount * pool.accAvocadoPerShare) - user.rewardDebt
        //
        // Whenever a user deposits or withdraws LP tokens to a pool. Here's what happens:
        //   1. The pool's `accAvocadoPerShare` (and `lastRewardBlock`) gets updated.
        //   2. User receives the pending reward sent to his/her address.
        //   3. User's `amount` gets updated.
        //   4. User's `rewardDebt` gets updated.
    }

    // Info of each pool.
    struct PoolInfo {
        IBEP20 lpToken;           // Address of LP token contract.
        uint256 allocPoint;       // How many allocation points assigned to this pool. Avocados to distribute per block.
        uint256 lastRewardBlock;  // Last block number that Avocados distribution occurs.
        uint256 accAvocadoPerShare;   // Accumulated Avocados per share, times 1e12. See below.
        uint16 depositFeeBP;      // Deposit fee in basis points
        uint256 harvestInterval;  // Harvest interval in seconds
        uint16 bonusMode;   // bonus mode
        uint256 nominalTotalBalance;
    }

    // The Avocado TOKEN!
    AvocadoToken public avocado;
    // Dev address.
    address public devAddress;
    // Deposit Fee address
    address public feeAddress;
    // Avocado tokens created per block.
    uint256 public avocadoPerBlock;
    // Bonus muliplier for early avocado makers.
    uint256 public constant BONUS_MULTIPLIER = 1;
    // Max harvest interval: 14 days.
    uint256 public constant MAXIMUM_HARVEST_INTERVAL = 14 days;

    // Info of each pool.
    PoolInfo[] public poolInfo;
    // Info of each user that stakes LP tokens.
    mapping(uint256 => mapping(address => UserInfo)) public userInfo;
    // Total allocation points. Must be the sum of all allocation points in all pools.
    uint256 public totalAllocPoint = 0;
    // The block number when Avocado mining starts.
    uint256 public startBlock;
    // Total locked up rewards
    uint256 public totalLockedUpRewards;

    // Avocado referral contract address.
    IAvocadoReferral public avocadoReferral;
    // Referral commission rate in basis points.
    uint16 public referralCommissionRate = 200;
    // Max referral commission rate: 10%.
    uint16 public constant MAXIMUM_REFERRAL_COMMISSION_RATE = 1000;

    event Deposit(address indexed user, uint256 indexed pid, uint256 amount);
    event Withdraw(address indexed user, uint256 indexed pid, uint256 amount);
    event EmergencyWithdraw(address indexed user, uint256 indexed pid, uint256 amount);
    event EmissionRateUpdated(address indexed caller, uint256 previousAmount, uint256 newAmount);
    event ReferralCommissionPaid(address indexed user, address indexed referrer, uint256 commissionAmount);
    event RewardLockedUp(address indexed user, uint256 indexed pid, uint256 amountLockedUp);

    constructor(
        AvocadoToken _avocado,
        uint256 _startBlock,
        uint256 _avocadoPerBlock
    ) public {
        avocado = _avocado;
        startBlock = _startBlock;
        avocadoPerBlock = _avocadoPerBlock;

        devAddress = msg.sender;
        feeAddress = msg.sender;
    }

    function poolLength() external view returns (uint256) {
        return poolInfo.length;
    }

    // Add a new lp to the pool. Can only be called by the owner.
    // XXX DO NOT add the same LP token more than once. Rewards will be messed up if you do.
    function add(uint256 _allocPoint, IBEP20 _lpToken, uint16 _depositFeeBP, uint256 _harvestInterval, bool _withUpdate) public onlyOwner {
        require(_depositFeeBP <= 10000, "add: invalid deposit fee basis points");
        require(_harvestInterval <= MAXIMUM_HARVEST_INTERVAL, "add: invalid harvest interval");
        if (_withUpdate) {
            massUpdatePools();
        }
        uint256 lastRewardBlock = block.number > startBlock ? block.number : startBlock;
        totalAllocPoint = totalAllocPoint.add(_allocPoint);
        poolInfo.push(PoolInfo({
            lpToken: _lpToken,
            allocPoint: _allocPoint,
            lastRewardBlock: lastRewardBlock,
            accAvocadoPerShare: 0,
            depositFeeBP: _depositFeeBP,
            harvestInterval: _harvestInterval,
            bonusMode: 0,
            nominalTotalBalance: 0
        }));
    }

    // Update the given pool's Avocado allocation point and deposit fee. Can only be called by the owner.
    function set(uint256 _pid, uint256 _allocPoint, uint16 _depositFeeBP, uint256 _harvestInterval, bool _withUpdate) public onlyOwner {
        require(_depositFeeBP <= 10000, "set: invalid deposit fee basis points");
        require(_harvestInterval <= MAXIMUM_HARVEST_INTERVAL, "set: invalid harvest interval");
        if (_withUpdate) {
            massUpdatePools();
        }
        totalAllocPoint = totalAllocPoint.sub(poolInfo[_pid].allocPoint).add(_allocPoint);
        poolInfo[_pid].allocPoint = _allocPoint;
        poolInfo[_pid].depositFeeBP = _depositFeeBP;
        poolInfo[_pid].harvestInterval = _harvestInterval;
    }

    function setBonusMode(uint256 _pid, uint16 _bonusMode) public onlyOwner {
        poolInfo[_pid].bonusMode = _bonusMode;
    }

    // Return reward multiplier over the given _from to _to block.
    function getMultiplier(uint256 _from, uint256 _to) public pure returns (uint256) {
        return _to.sub(_from).mul(BONUS_MULTIPLIER);
    }

    // View function to see pending Avocados on frontend.
    function pendingAvocado(uint256 _pid, address _user) external view returns (uint256) {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][_user];
        uint16 _bonusMultiplier = user.bonusMultiplier;
        if (_bonusMultiplier == 0)
            _bonusMultiplier = 10;
        uint256 accAvocadoPerShare = pool.accAvocadoPerShare;
        uint256 lpSupply = pool.lpToken.balanceOf(address(this));
        if (pool.bonusMode == 1) {
            if (pool.nominalTotalBalance > 0) {
                lpSupply = pool.nominalTotalBalance;
            }
        }
        if (block.number > pool.lastRewardBlock && lpSupply != 0) {
            uint256 multiplier = getMultiplier(pool.lastRewardBlock, block.number);
            uint256 avocadoReward = multiplier.mul(avocadoPerBlock).mul(pool.allocPoint).div(totalAllocPoint);
            accAvocadoPerShare = accAvocadoPerShare.add(avocadoReward.mul(1e12).div(lpSupply));
        }
        uint256 pending = user.amount.mul(_bonusMultiplier).div(10).mul(accAvocadoPerShare).div(1e12).sub(user.rewardDebt);
        return pending.add(user.rewardLockedUp);
    }

    // View function to see if user can harvest Avocados.
    function canHarvest(uint256 _pid, address _user) public view returns (bool) {
        UserInfo storage user = userInfo[_pid][_user];
        return block.timestamp >= user.nextHarvestUntil;
    }

    // Update reward variables for all pools. Be careful of gas spending!
    function massUpdatePools() public {
        uint256 length = poolInfo.length;
        for (uint256 pid = 0; pid < length; ++pid) {
            updatePool(pid);
        }
    }

    function calculateBonusMultiplier(uint256 _timerStartedAt) internal view returns (uint16) {
        uint16 _bonusMultiplier = 10;
        if (_timerStartedAt == 0) {
            return _bonusMultiplier;
        }
        uint256 _timePassed = block.timestamp - _timerStartedAt;
        if (_timePassed >= 90 days) {
            _bonusMultiplier = 50;
        } else if (_timePassed >= 60 days) {
            _bonusMultiplier = 40;
        } else if (_timePassed >= 30 days) {
            _bonusMultiplier = 30;
        } else if (_timePassed >= 14 days) {
            _bonusMultiplier = 20;
        } else if (_timePassed >= 10 days) {
            _bonusMultiplier = 18;
        } else if (_timePassed >= 7 days) {
            _bonusMultiplier = 15;
        }
        return _bonusMultiplier;
    }

    // Update reward variables of the given pool to be up-to-date.
    function updatePool(uint256 _pid) public {
        PoolInfo storage pool = poolInfo[_pid];
        if (block.number <= pool.lastRewardBlock) {
            return;
        }
        uint256 lpSupply = pool.lpToken.balanceOf(address(this));
        if (pool.bonusMode == 1) {
            if (pool.nominalTotalBalance > 0) {
                lpSupply = pool.nominalTotalBalance;
            } else {
                pool.nominalTotalBalance = lpSupply;
            }
        }
        if (lpSupply == 0 || pool.allocPoint == 0) {
            pool.lastRewardBlock = block.number;
            return;
        }
        uint256 multiplier = getMultiplier(pool.lastRewardBlock, block.number);
        uint256 avocadoReward = multiplier.mul(avocadoPerBlock).mul(pool.allocPoint).div(totalAllocPoint);
        avocado.mint(devAddress, avocadoReward.div(10));
        avocado.mint(address(this), avocadoReward);
        pool.accAvocadoPerShare = pool.accAvocadoPerShare.add(avocadoReward.mul(1e12).div(lpSupply));
        pool.lastRewardBlock = block.number;
    }

    // Deposit LP tokens to MasterChef for Avocado allocation.
    function deposit(uint256 _pid, uint256 _amount, address _referrer) public nonReentrant {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];
        if (user.bonusMultiplier == 0)
            user.bonusMultiplier = 10;
        updatePool(_pid);
        if (_amount > 0 && address(avocadoReferral) != address(0) && _referrer != address(0) && _referrer != msg.sender) {
            avocadoReferral.recordReferral(msg.sender, _referrer);
        }
        pool.nominalTotalBalance = pool.nominalTotalBalance.sub(user.amount.mul(user.bonusMultiplier).div(10));
        payOrLockupPendingAvocado(_pid);        
        if (_amount > 0) {
            pool.lpToken.safeTransferFrom(address(msg.sender), address(this), _amount);
            if (address(pool.lpToken) == address(avocado)) {
                uint256 transferTax = _amount.mul(avocado.transferTaxRate()).div(10000);
                _amount = _amount.sub(transferTax);
            }
            if (pool.depositFeeBP > 0) {
                uint256 depositFee = _amount.mul(pool.depositFeeBP).div(10000);
                pool.lpToken.safeTransfer(feeAddress, depositFee);
                user.amount = user.amount.add(_amount).sub(depositFee);
            } else {
                user.amount = user.amount.add(_amount);
            }
            // update user bonus status
            if (!user.bonusTimerStarted) {
                user.bonusTimerStarted = true;
            }            
        }
        if (user.bonusTimerStarted && user.timerStartedAt == 0) {
            if (block.number >= startBlock) {
                user.timerStartedAt = block.timestamp;
            }
        }
        // plus nominal balance
        pool.nominalTotalBalance = pool.nominalTotalBalance.add(user.amount.mul(user.bonusMultiplier).div(10));
        user.rewardDebt = user.amount.mul(user.bonusMultiplier).div(10).mul(pool.accAvocadoPerShare).div(1e12);
        emit Deposit(msg.sender, _pid, _amount);
    }

    // Withdraw LP tokens from MasterChef.
    function withdraw(uint256 _pid, uint256 _amount) public nonReentrant {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];
        if (user.bonusMultiplier == 0)
            user.bonusMultiplier = 10;
        require(user.amount >= _amount, "withdraw: not good");
        updatePool(_pid);
        pool.nominalTotalBalance = pool.nominalTotalBalance.sub(user.amount.mul(user.bonusMultiplier).div(10));
        payOrLockupPendingAvocado(_pid);
        if (_amount > 0) {            
            user.amount = user.amount.sub(_amount);
            pool.lpToken.safeTransfer(address(msg.sender), _amount);
            // update user bonus status
            if (user.bonusTimerStarted) {
                user.bonusTimerStarted = false;
                user.timerStartedAt = 0;
                user.bonusMultiplier = 10;
            }            
        }
        // sub nominal balance            
        pool.nominalTotalBalance = pool.nominalTotalBalance.add(user.amount.mul(user.bonusMultiplier).div(10));
        user.rewardDebt = user.amount.mul(user.bonusMultiplier).div(10).mul(pool.accAvocadoPerShare).div(1e12);
        emit Withdraw(msg.sender, _pid, _amount);
    }

    // Withdraw without caring about rewards. EMERGENCY ONLY.
    function emergencyWithdraw(uint256 _pid) public nonReentrant {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];
        if (user.bonusMultiplier == 0)
            user.bonusMultiplier = 10;
        uint256 amount = user.amount;
        user.amount = 0;
        user.rewardDebt = 0;
        user.rewardLockedUp = 0;
        user.nextHarvestUntil = 0;
        pool.lpToken.safeTransfer(address(msg.sender), amount);
        // update nominal balance and user bonus status
        pool.nominalTotalBalance = pool.nominalTotalBalance.sub(user.amount.mul(user.bonusMultiplier).div(10));        
        user.bonusTimerStarted = false;
        user.timerStartedAt = 0;
        user.bonusMultiplier = 10;
        emit EmergencyWithdraw(msg.sender, _pid, amount);
    }

    // Pay or lockup pending Avocados.
    function payOrLockupPendingAvocado(uint256 _pid) internal {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];

        if (user.nextHarvestUntil == 0) {
            user.nextHarvestUntil = block.timestamp.add(pool.harvestInterval);
        }

        uint256 pending = user.amount.mul(user.bonusMultiplier).div(10).mul(pool.accAvocadoPerShare).div(1e12).sub(user.rewardDebt);
        if (canHarvest(_pid, msg.sender)) {
            if (pending > 0 || user.rewardLockedUp > 0) {
                uint256 totalRewards = pending.add(user.rewardLockedUp);

                // reset lockup
                totalLockedUpRewards = totalLockedUpRewards.sub(user.rewardLockedUp);
                user.rewardLockedUp = 0;
                user.nextHarvestUntil = block.timestamp.add(pool.harvestInterval);

                // send rewards
                safeAvocadoTransfer(msg.sender, totalRewards);
                payReferralCommission(msg.sender, totalRewards.mul(10).div(user.bonusMultiplier));

                // update the bonus multiplier
                if (pool.bonusMode == 1) {
                    if (user.bonusTimerStarted) {
                        if (user.timerStartedAt == 0) {
                            user.timerStartedAt = block.timestamp;
                        }
                        user.bonusMultiplier = calculateBonusMultiplier(user.timerStartedAt);
                    }
                }
            }
        } else if (pending > 0) {
            user.rewardLockedUp = user.rewardLockedUp.add(pending);
            totalLockedUpRewards = totalLockedUpRewards.add(pending);
            emit RewardLockedUp(msg.sender, _pid, pending);
        }
    }

    // Safe avocado transfer function, just in case if rounding error causes pool to not have enough Avocados.
    function safeAvocadoTransfer(address _to, uint256 _amount) internal {
        uint256 avocadoBal = avocado.balanceOf(address(this));
        if (_amount > avocadoBal) {
            avocado.transfer(_to, avocadoBal);
        } else {
            avocado.transfer(_to, _amount);
        }
    }

    // Update dev address by the previous dev.
    function setDevAddress(address _devAddress) public {
        require(msg.sender == devAddress, "setDevAddress: FORBIDDEN");
        require(_devAddress != address(0), "setDevAddress: ZERO");
        devAddress = _devAddress;
    }

    function setFeeAddress(address _feeAddress) public {
        require(msg.sender == feeAddress, "setFeeAddress: FORBIDDEN");
        require(_feeAddress != address(0), "setFeeAddress: ZERO");
        feeAddress = _feeAddress;
    }

    // Pancake has to add hidden dummy pools in order to alter the emission, here we make it simple and transparent to all.
    function updateEmissionRate(uint256 _avocadoPerBlock) public onlyOwner {
        massUpdatePools();
        emit EmissionRateUpdated(msg.sender, avocadoPerBlock, _avocadoPerBlock);
        avocadoPerBlock = _avocadoPerBlock;
    }

    // Update the avocado referral contract address by the owner
    function setAvocadoReferral(IAvocadoReferral _avocadoReferral) public onlyOwner {
        avocadoReferral = _avocadoReferral;
    }

    // Update referral commission rate by the owner
    function setReferralCommissionRate(uint16 _referralCommissionRate) public onlyOwner {
        require(_referralCommissionRate <= MAXIMUM_REFERRAL_COMMISSION_RATE, "setReferralCommissionRate: invalid referral commission rate basis points");
        referralCommissionRate = _referralCommissionRate;
    }

    // Pay referral commission to the referrer who referred this user.
    function payReferralCommission(address _user, uint256 _pending) internal {
        if (address(avocadoReferral) != address(0) && referralCommissionRate > 0) {
            address referrer = avocadoReferral.getReferrer(_user);
            uint256 commissionAmount = _pending.mul(referralCommissionRate).div(10000);

            if (referrer != address(0) && commissionAmount > 0) {
                avocado.mint(referrer, commissionAmount);
                avocadoReferral.recordReferralCommission(referrer, commissionAmount);
                emit ReferralCommissionPaid(_user, referrer, commissionAmount);
            }
        }
    }
}
