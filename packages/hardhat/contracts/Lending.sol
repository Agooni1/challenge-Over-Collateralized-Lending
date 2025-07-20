// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/Ownable.sol";
import "./Corn.sol";
import "./CornDEX.sol";

interface IFlashLoanRecipient{
    function executeOperation(uint256 amount, address initiator, address extraParam) external returns (bool);
}

error Lending__InvalidAmount();
error Lending__TransferFailed();
error Lending__UnsafePositionRatio();
error Lending__BorrowingFailed();
error Lending__RepayingFailed();
error Lending__PositionSafe();
error Lending__NotLiquidatable();
error Lending__InsufficientLiquidatorCorn();
error Lending__FlashLoanFailed();

contract Lending is Ownable {
    uint256 private constant COLLATERAL_RATIO = 120; // 120% collateralization required
    uint256 private constant LIQUIDATOR_REWARD = 10; // 10% reward for liquidators

    Corn private i_corn;
    CornDEX private i_cornDEX;

    mapping(address => uint256) public s_userCollateral; // User's collateral balance
    mapping(address => uint256) public s_userBorrowed; // User's borrowed corn balance

    event CollateralAdded(address indexed user, uint256 indexed amount, uint256 price);
    event CollateralWithdrawn(address indexed user, uint256 indexed amount, uint256 price);
    event AssetBorrowed(address indexed user, uint256 indexed amount, uint256 price);
    event AssetRepaid(address indexed user, uint256 indexed amount, uint256 price);
    event Liquidation(
        address indexed user,
        address indexed liquidator,
        uint256 amountForLiquidator,
        uint256 liquidatedUserDebt,
        uint256 price
    );

    constructor(address _cornDEX, address _corn) Ownable(msg.sender) {
        i_cornDEX = CornDEX(_cornDEX);
        i_corn = Corn(_corn);
        i_corn.approve(address(this), type(uint256).max);
    }

    /**
     * @notice Allows users to add collateral to their account
     */
    function addCollateral() public payable {
        if (msg.value == 0) {
            revert Lending__InvalidAmount();
        }
        s_userCollateral[msg.sender] += msg.value;
        emit CollateralAdded(msg.sender, msg.value, i_cornDEX.currentPrice());
    }

    /**
     * @notice Allows users to withdraw collateral as long as it doesn't make them liquidatable
     * @param _amount The amount of collateral to withdraw
     */
    function withdrawCollateral(uint256 _amount) public {
        if (_amount == 0 || s_userCollateral[msg.sender] < _amount) {
            revert Lending__InvalidAmount();
        }
        uint256 newCollateral = s_userCollateral[msg.sender] -= _amount;
        s_userCollateral[msg.sender] = newCollateral;
        if (s_userBorrowed[msg.sender]!=0){
            _validatePosition(msg.sender);
        }

        (bool success, ) = payable(msg.sender).call{value: _amount}("");
        if (!success) {
            revert Lending__TransferFailed();
        }
        
        emit CollateralWithdrawn(msg.sender, _amount, i_cornDEX.currentPrice());
    }

    /**
     * @notice Calculates the total collateral value for a user based on their collateral balance
     * @param user The address of the user to calculate the collateral value for
     * @return uint256 The collateral value
     */
    function calculateCollateralValue(address user) public view returns (uint256) {
        uint256 currentCollateral = s_userCollateral[user];
        return (currentCollateral * i_cornDEX.currentPrice()) / 1e18;
    }

    /**
     * @notice Calculates the position ratio for a user to ensure they are within safe limits
     * @param user The address of the user to calculate the position ratio for
     * @return uint256 The position ratio
     */
    function _calculatePositionRatio(address user) internal view returns (uint256) {
        uint256 userCollateralinCORN = calculateCollateralValue(user);
        uint256 userBorrowed = s_userBorrowed[user];
        if (userBorrowed == 0){
            return type(uint256).max;
        }

        return (userCollateralinCORN * 1e18) / userBorrowed;
    }

    /**
     * @notice Checks if a user's position can be liquidated
     * @param user The address of the user to check
     * @return bool True if the position is liquidatable, false otherwise
     */
    function isLiquidatable(address user) public view returns (bool) {
        //logic given in challenge results in overflow error when value is type(uint256).max and is then *100
        if (s_userBorrowed[user] == 0) {
            return false;
        }
        uint256 userpositionratio = _calculatePositionRatio(user);
        return (userpositionratio * 100) < (COLLATERAL_RATIO * 1e18);
    }

    /**
     * @notice Internal view method that reverts if a user's position is unsafe
     * @param user The address of the user to validate
     */
    function _validatePosition(address user) internal view {
        if(isLiquidatable(user)){
            revert Lending__UnsafePositionRatio();
        }
    }

    /**
     * @notice Allows users to borrow corn based on their collateral
     * @param borrowAmount The amount of corn to borrow
     */
    function borrowCorn(uint256 borrowAmount) public {
        if (borrowAmount == 0){
            revert Lending__InvalidAmount();
        }
        s_userBorrowed[msg.sender]+=borrowAmount;
        _validatePosition(msg.sender);

        bool success = i_corn.transferFrom(address(this), msg.sender, borrowAmount);
        if(!success){
            revert Lending__BorrowingFailed();
        }
        emit AssetBorrowed(msg.sender, borrowAmount, i_cornDEX.currentPrice());
    }

    /**
     * @notice Allows users to repay corn and reduce their debt
     * @param repayAmount The amount of corn to repay
     */
    function repayCorn(uint256 repayAmount) public {
        if (repayAmount == 0 || repayAmount > s_userBorrowed[msg.sender]){
            revert Lending__InvalidAmount();
        }

        s_userBorrowed[msg.sender] -= repayAmount;
        bool success = i_corn.transferFrom(msg.sender, address(this), repayAmount);
        if (!success){
            revert Lending__RepayingFailed();
        }
        emit AssetRepaid(msg.sender, repayAmount, i_cornDEX.currentPrice());
    }

    /**
     * @notice Allows liquidators to liquidate unsafe positions
     * @param user The address of the user to liquidate
     * @dev The caller must have enough CORN to pay back user's debt
     * @dev The caller must have approved this contract to transfer the debt
     */
    function liquidate(address user) public {

        if(!isLiquidatable(user)){
            revert Lending__NotLiquidatable();
        }

        if (i_corn.balanceOf(msg.sender) < s_userBorrowed[user]){
            revert Lending__InsufficientLiquidatorCorn();
        }

        uint256 userBorrowed = s_userBorrowed[user];
        uint256 userCollateral = s_userCollateral[user];

        // console.log("liquidate i_corn transferFrom msg.sender:");
        // console.logAddress(msg.sender);
        i_corn.transferFrom(msg.sender, address(this), userBorrowed);
        
        
       
        s_userBorrowed[user] = 0;

        uint256 userBorrowedinEth = userBorrowed * 1e18 / i_cornDEX.currentPrice();
        uint256 reward = userBorrowedinEth * LIQUIDATOR_REWARD / 100;
        uint256 finalreward = userBorrowedinEth + reward;

        if (finalreward > userCollateral){
            finalreward = userCollateral;
        }

        s_userCollateral[user] -=finalreward;

        (bool success, ) = payable(msg.sender).call{value: finalreward}("");
        if (!success) {
            revert Lending__TransferFailed();
        }
        emit Liquidation(user, msg.sender, finalreward, userBorrowed, i_cornDEX.currentPrice());

    }

    function flashLoan(IFlashLoanRecipient _recipient, uint256 _amount, address _extraParam) public {
        // console.log("INSIDE FLASHLOAN");
        // console.log("lending corn balance:", i_corn.balanceOf(address(this)));
        i_corn.mintTo(address(_recipient), _amount); //pretty sure we have to make the lending contract the CORN owner to do this
        // console.log("AFTER MINTING");
        // console.log("CORN balance:", i_corn.balanceOf(address(_recipient)));
        if (!_recipient.executeOperation(_amount, msg.sender, _extraParam)) {
            revert Lending__FlashLoanFailed();
        }
        // console.log("AFTER EXECUTE OPERATION");
        
        // I really don't understand the given implementation. I guess it's trusting things to be returned?
        // if executeOperation is set to literally just return True, this will just burn the contract's own corn balance.
        // i_corn.burnFrom(address(this), i_corn.balanceOf(address(this)));

        i_corn.transferFrom(address(_recipient), address(this), _amount);
        i_corn.burnFrom(address(this), _amount); //I guess we still use this to not increase the total supply
        // console.log("AFTER BURNING");
        // console.log("Lending corn balance:", i_corn.balanceOf(address(this)));
    }

    function getMaxBorrowAmount(uint256 _ethAmount) public view returns (uint256) {
        uint256 xReserves = address(i_cornDEX).balance;
        uint256 yReserves = i_corn.balanceOf(address(i_cornDEX));
        uint256 yOutput = i_cornDEX.price(_ethAmount, xReserves, yReserves);
        uint256 maxBorrowAmount = (yOutput * 100) / COLLATERAL_RATIO;
        return maxBorrowAmount;
    }

    function getMaxWithdrawableCollateral(address _user) public view returns (uint256) {
        uint256 userCollateral = s_userCollateral[_user];
        uint256 userBorrowed = s_userBorrowed[_user];

        if (userBorrowed ==0 ){
            return userCollateral;
        }

        uint256 minCollateral = (userBorrowed * 1e18 * COLLATERAL_RATIO)  / (i_cornDEX.currentPrice() * 100);

        if (userCollateral <= minCollateral ){
            return 0;
        }
        //slight buffer because when you try to withdraw the exact max with potential rounding it causes errors I think
        // SRE implementation produces slightly smaller values (97% of what this produces)
        // Pretty sure on paper both approaches are mathematically equivalent but I think due to rounding my implementaion value without slight reduction will result in withdrawal errors
        return ((userCollateral - minCollateral) * 100 / 101); 
        
    }
    // function getMaxWithdrawableCollateral(address user) public view returns (uint256) {
    //     uint256 borrowedAmount = s_userBorrowed[user];
    //     uint256 userCollateral = s_userCollateral[user];
    //     if (borrowedAmount == 0) return userCollateral;

    //     uint256 maxBorrowedAmount = getMaxBorrowAmount(userCollateral);
    //     if (borrowedAmount == maxBorrowedAmount) return 0;

    //     uint256 potentialBorrowingAmount = maxBorrowedAmount - borrowedAmount;
    //     uint256 ethValueOfPotentialBorrowingAmount = (potentialBorrowingAmount * 1e18) / i_cornDEX.currentPrice();

    //     return (ethValueOfPotentialBorrowingAmount * COLLATERAL_RATIO) / 100;
    // }
}