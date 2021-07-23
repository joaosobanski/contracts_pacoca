/**
                                                         __
     _____      __      ___    ___     ___     __       /\_\    ___
    /\ '__`\  /'__`\   /'___\ / __`\  /'___\ /'__`\     \/\ \  / __`\
    \ \ \_\ \/\ \_\.\_/\ \__//\ \_\ \/\ \__//\ \_\.\_  __\ \ \/\ \_\ \
     \ \ ,__/\ \__/.\_\ \____\ \____/\ \____\ \__/.\_\/\_\\ \_\ \____/
      \ \ \/  \/__/\/_/\/____/\/___/  \/____/\/__/\/_/\/_/ \/_/\/___/
       \ \_\
        \/_/

    The sweetest DeFi portfolio manager.

**/

// SPDX-License-Identifier: MIT

pragma solidity 0.6.12;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";
import "./interfaces/IPancakeswapFarm.sol";
import "./interfaces/IPancakeRouter01.sol";
import "./interfaces/IAutoPacoca.sol";

contract SweetVault is Ownable, ReentrancyGuard {
    using SafeMath for uint256;
    using SafeERC20 for IERC20;

    struct UserInfo {
        // How many assets the user has provided.
        uint256 stake;
        // How many staked $PACOCA user had at his last action
        uint256 pacocaShares;
        // Pacoca shares not entitled to the user
        uint256 rewardDebt;
    }

    // Addresses
    address constant public BURN_ADDRESS = 0x000000000000000000000000000000000000dEaD;
    address constant public WBNB = 0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c;
    IERC20 constant public PACOCA = IERC20(0x55671114d774ee99D653D6C12460c780a67f1D18);
    IAutoPacoca immutable public AUTO_PACOCA;
    IERC20 immutable public STAKED_TOKEN;

    // Runtime data
    mapping(address => UserInfo) public userInfo; // Info of users
    uint256 public accSharesPerStakedToken; // Accumulated AUTO_PACOCA shares per staked token, times 1e18.

    // Farm info
    IPancakeswapFarm immutable public STAKED_TOKEN_FARM;
    IERC20 immutable public REWARD_TOKEN;
    uint256 immutable public FARM_PID;
    bool immutable IS_CAKE_STAKING;

    // Settings
    IPancakeRouter01 public router;
    address[] public path; // Path from staked token to PACOCA
    address public keeper;
    uint256 public keeperFee = 50; // 0.5%
    uint256 public constant keeperFeeUL = 100; // 1%
    uint256 public buyBackRate = 300; // 3%
    uint256 public constant buyBackRateUL = 800; // 8%

    event Deposit(address indexed user, uint256 amount);
    event Withdraw(address indexed user, uint256 amount);
    event ClaimRewards(address indexed user, uint256 shares, uint256 amount);

    // Setting updates
    event SetRouter(address oldRouter, address newRouter);
    event SetPath(address[] oldPath, address[] newPath);
    event SetBuyBackRate(uint256 oldBuyBackRate, uint256 newBuyBackRate);
    event SetKeeper(address oldKeeper, address newKeeper);
    event SetKeeperFee(address oldKeeperFee, address newKeeperFee);

    constructor(
        address _autoPacoca,
        address _stakedToken,
        address _stakedTokenFarm,
        address _rewardToken,
        uint256 _farmPid,
        bool _isCakeStaking,
        address _router,
        address[] memory _path,
        address _owner,
        address _keeper
    ) public {
        AUTO_PACOCA = IAutoPacoca(_autoPacoca);
        STAKED_TOKEN = IERC20(_stakedToken);
        STAKED_TOKEN_FARM = IPancakeswapFarm(_stakedTokenFarm);
        REWARD_TOKEN = IERC20(_rewardToken);
        FARM_PID = _farmPid;
        IS_CAKE_STAKING = _isCakeStaking;

        router = IPancakeRouter01(_router);
        path = _path;

        transferOwnership(_owner);
        keeper = _keeper;
    }

    /**
     * @dev Throws if called by any account other than the keeper.
     */
    modifier onlyKeeper() {
        require(keeper == msg.sender, "SweetVault: caller is not the keeper");
        _;
    }

    // 1. Harvest rewards
    // 2. Convert rewards to $PACOCA
    // 3. Collect fees
    // 4. Stake to pacoca auto-compound vault
    function earn(uint256 _minPacocaOutput) external onlyKeeper {
        if (IS_CAKE_STAKING) {
            STAKED_TOKEN_FARM.leaveStaking(0);
        } else {
            STAKED_TOKEN_FARM.withdraw(FARM_PID, 0);
        }

        _convertBalanceToPacoca(_minPacocaOutput);

        uint256 balanceBeforeFees = _pacocaBalance();

        _safePACOCATransfer(
            BURN_ADDRESS,
            balanceBeforeFees.mul(buyBackRate).div(10000)
        );

        _safePACOCATransfer(
            keeper,
            balanceBeforeFees.mul(keeperFee).div(10000)
        );

        uint256 previousShares = AUTO_PACOCA.sharesOf(address(this));
        uint256 pacocaBalance = _pacocaBalance();

        _approveTokenIfNeeded(
            PACOCA,
            pacocaBalance,
            address(AUTO_PACOCA)
        );

        AUTO_PACOCA.deposit(pacocaBalance);

        uint256 currentShares = AUTO_PACOCA.sharesOf(address(this));

        accSharesPerStakedToken = accSharesPerStakedToken.add(
            currentShares.sub(previousShares).mul(1e18).div(totalStake())
        );
    }

    function deposit(uint256 _amount) external nonReentrant {
        require(_amount > 0, "SweetVault: amount must be greater than zero");

        UserInfo storage user = userInfo[msg.sender];

        STAKED_TOKEN.safeTransferFrom(
            address(msg.sender),
            address(this),
            _amount
        );

        _approveTokenIfNeeded(
            STAKED_TOKEN,
            _amount,
            address(STAKED_TOKEN_FARM)
        );

        if (IS_CAKE_STAKING) {
            STAKED_TOKEN_FARM.enterStaking(_amount);
        } else {
            STAKED_TOKEN_FARM.deposit(FARM_PID, _amount);
        }

        user.pacocaShares = user.pacocaShares.add(
            user.stake.mul(accSharesPerStakedToken).div(1e18).sub(
                user.rewardDebt
            )
        );
        user.stake = user.stake.add(_amount);
        user.rewardDebt = user.stake.mul(accSharesPerStakedToken).div(1e18);

        emit Deposit(msg.sender, _amount);
    }

    function withdraw(uint256 _amount) external nonReentrant {
        UserInfo storage user = userInfo[msg.sender];

        require(_amount > 0, "SweetVault: amount must be greater than zero");
        require(user.stake >= _amount, "SweetVault: withdraw amount exceeds balance");

        if (IS_CAKE_STAKING) {
            STAKED_TOKEN_FARM.leaveStaking(_amount);
        } else {
            STAKED_TOKEN_FARM.withdraw(FARM_PID, _amount);
        }

        user.pacocaShares = user.pacocaShares.add(
            user.stake.mul(accSharesPerStakedToken).div(1e18).sub(
                user.rewardDebt
            )
        );
        user.stake = user.stake.sub(_amount);
        user.rewardDebt = user.stake.mul(accSharesPerStakedToken).div(1e18);

        // Withdraw pacoca rewards if user leaves
        if (user.stake == 0 && user.pacocaShares > 0) {
            _claimRewards(user.pacocaShares);
        }

        STAKED_TOKEN.safeTransfer(msg.sender, _amount);

        emit Withdraw(msg.sender, _amount);
    }

    function claimRewards(uint256 _shares) public nonReentrant {
        _claimRewards(_shares);
    }

    function _claimRewards(uint256 _shares) private {
        UserInfo storage user = userInfo[msg.sender];

        require(user.pacocaShares >= _shares, "SweetVault: claim amount exceeds balance");

        user.pacocaShares = user.pacocaShares.sub(_shares);

        uint256 pricePerShare = AUTO_PACOCA.getPricePerFullShare();
        uint256 pacocaAmount = _shares.mul(pricePerShare).div(1e18);

        AUTO_PACOCA.withdraw(_shares);

        _safePACOCATransfer(msg.sender, pacocaAmount);

        emit ClaimRewards(msg.sender, _shares, pacocaAmount);
    }

    function getExpectedPacocaOutput() external view returns (uint256) {
        uint256 rewards = _rewardTokenBalance().add(
            STAKED_TOKEN_FARM.pendingCake(FARM_PID, address(this))
        );

        uint256[] memory amounts = router.getAmountsOut(rewards, path);

        return amounts[amounts.length.sub(1)];
    }

    function balanceOf(
        address _user
    ) external view returns (
        uint256 stake,
        uint256 rewards,
        uint256 rewardShares
    ) {
        UserInfo memory user = userInfo[_user];

        uint256 pendingShares = user.stake.mul(accSharesPerStakedToken).div(1e18).sub(
            user.rewardDebt
        );

        stake = user.stake;
        rewardShares = user.pacocaShares.add(pendingShares);
        rewards = rewardShares.mul(AUTO_PACOCA.getPricePerFullShare()).div(1e18);
    }

    function _approveTokenIfNeeded(
        IERC20 _token,
        uint256 _amount,
        address _spender
    ) private {
        if (_token.allowance(address(this), _spender) < _amount) {
            _token.safeApprove(_spender, uint(- 1));
        }
    }

    function _rewardTokenBalance() private view returns (uint256) {
        return REWARD_TOKEN.balanceOf(address(this));
    }

    function _pacocaBalance() private view returns (uint256) {
        return PACOCA.balanceOf(address(this));
    }

    function totalAutoPacocaShares() external view returns (uint256) {
        return AUTO_PACOCA.sharesOf(address(this));
    }

    function totalStake() public view returns (uint256) {
        return STAKED_TOKEN_FARM.userInfo(FARM_PID, address(this));
    }

    // Safe PACOCA transfer function, just in case if rounding error causes pool to not have enough
    function _safePACOCATransfer(address _to, uint256 _amount) private {
        uint256 balance = _pacocaBalance();

        if (_amount > balance) {
            PACOCA.transfer(_to, balance);
        } else {
            PACOCA.transfer(_to, _amount);
        }
    }

    function _convertBalanceToPacoca(uint256 _minPacocaOutput) private {
        uint256 rewardTokenBalance = _rewardTokenBalance();

        _approveTokenIfNeeded(
            REWARD_TOKEN,
            rewardTokenBalance,
            address(router)
        );

        router.swapExactTokensForTokens(
            rewardTokenBalance, // input amount
            _minPacocaOutput,
            path, // path
            address(this), // to
            block.timestamp // deadline
        );
    }

    function setRouter(address _router) public onlyOwner {
        address oldRouter = address(router);

        router = IPancakeRouter01(_router);

        emit SetRouter(oldRouter, _router);
    }

    function setPath(address[] memory _path) public onlyOwner {
        address[] memory oldPath = path;

        path = _path;

        emit SetPath(oldPath, path);
    }

    function setKeeper(address _keeper) public onlyOwner {
        address oldKeeper = keeper;

        keeper = _keeper;

        emit SetKeeper(oldKeeper, keeper);
    }

    function setKeeperFee(uint256 _keeperFee) public onlyOwner {
        require(_keeperFee <= keeperFeeUL, "SweetVault: Keeper fee too high");

        uint256 oldKeeperFee = keeperFee;

        keeperFee = _keeperFee;

        emit SetBuyBackRate(oldKeeperFee, keeperFee);
    }

    function setBuyBackRate(uint256 _buyBackRate) public onlyOwner {
        require(_buyBackRate <= buyBackRateUL, "SweetVault: BuyBackRate too high");

        uint256 oldBuyBackRate = buyBackRate;

        buyBackRate = _buyBackRate;

        emit SetBuyBackRate(oldBuyBackRate, buyBackRate);
    }
}
