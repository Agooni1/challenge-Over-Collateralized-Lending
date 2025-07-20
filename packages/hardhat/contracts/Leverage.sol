// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import { Lending } from "./Lending.sol";
import { CornDEX } from "./CornDEX.sol";
import { Corn } from "./Corn.sol";
// import "hardhat/console.sol";

/**
 * @notice For Side quest only
 * @notice This contract is used to leverage a user's position by borrowing CORN from the Lending contract
 * then borrowing more CORN from the DEX to repay the initial borrow then repeating until the user has borrowed as much as they want
 */
contract Leverage {
    Lending i_lending;
    CornDEX i_cornDEX;
    Corn i_corn;
    address public owner;

    event LeveragedPositionOpened(address user, uint256 loops);
    event LeveragedPositionClosed(address user, uint256 loops);

    modifier onlyOwner() {
        require(msg.sender == owner, "Only the owner can call this function");
        _;
    }

    constructor(address _lending, address _cornDEX, address _corn) {
        i_lending = Lending(_lending);
        i_cornDEX = CornDEX(_cornDEX);
        i_corn = Corn(_corn);
        // Approve the DEX to spend the user's CORN
        i_corn.approve(address(i_cornDEX), type(uint256).max);
        i_corn.approve(address(i_lending), type(uint256).max);
    }
    
    /**
     * @notice Claim ownership of the contract so that no one else can change your position or withdraw your funds
     */
    function claimOwnership() public {
        owner = msg.sender;
    }

    /**
     * @notice Open a leveraged position, iteratively borrowing CORN, swapping it for ETH, and adding it as collateral
     * @param reserve The amount of ETH that we will keep in the contract as a reserve to prevent liquidation
     */
    function openLeveragedPosition(uint256 reserve) public payable onlyOwner {
        uint256 loops = 0;
        uint256 MIN_AMOUNT = 0.001 ether; //MIN amount because when reserve = exactly 0 (i.e. not given), this contract will try to lend near 0 values near the "end" which I think is what causes errors
        require(msg.value >= reserve, "Reserve must be less than the amount sent");
        require(msg.value > 0, "Must send some ETH to open a position");
        
        // console.log("-----------START-----------");
        // console.log("Initial _amount: ", _amount);
        // console.log("Reserve: ", reserve);
        
        while (true) {
            // console.log ("-----------BEGINNING OF LOOP-----------");
            // console.log ("_amount: ", _amount);
            // console.log("CORN balance: ", i_corn.balanceOf(address(this)));
            // console.log("ETH balance: ", address(this).balance);
            uint256 _amount = address(this).balance;

            i_lending.addCollateral{value: _amount}();

            if (_amount <= reserve || _amount < MIN_AMOUNT) { //SRE implementation can break if no reserve given (i.e. reserve = 0)
                // console.log("-----------END-----------");
                break;
            }

            uint256 maxBorrow = i_lending.getMaxBorrowAmount(_amount);

            i_lending.borrowCorn(maxBorrow);

            i_cornDEX.swap(i_corn.balanceOf(address(this)));

            // console.log("AFTER LOGIC");
            // console.log("_amount: ", _amount);    
            // console.log("CORN balance: ", i_corn.balanceOf(address(this)));
            // console.log("ETH balance: ", address(this).balance);

            loops++;
            // console.log ("-----------END OF LOOP-----------");
        }
        emit LeveragedPositionOpened(msg.sender, loops);
    }

    

    /**
     * @notice Close a leveraged position, iteratively withdrawing collateral, swapping it for CORN, and repaying the lending contract until the position is closed
     */
    function closeLeveragedPosition() public onlyOwner {
        // console.log("-----------START-----------");
        uint256 loops = 0;
        while (true) {
            // console.log ("-----------START OF LOOP-----------");
            uint256 _amount = i_lending.getMaxWithdrawableCollateral(address(this)); // safety buffer becasue trying to withdraw the exact max caused me errors idk if they were rounding errors or what
            // console.log("_amount: ", _amount);
            // console.log("CORN balance: ", i_corn.balanceOf(address(this)));

            i_lending.withdrawCollateral(_amount);
            // console.log("AFTER WITHDRAWAL");
            // console.log("ETH balance: ", address(this).balance);
            // console.log("CORN balance: ", i_corn.balanceOf(address(this)));
            uint256 cornDebt = i_lending.s_userBorrowed(address(this));
            // console.log("CORN debt: ", cornDebt);
            i_cornDEX.swap{value:_amount}(_amount);
            uint256 cornBalance = i_corn.balanceOf(address(this));
            // console.log("AFTER SWAP");
            // console.log("CORN balance: ", i_corn.balanceOf(address(this)));
            if (cornBalance < cornDebt) {
                 i_lending.repayCorn(i_corn.balanceOf(address(this)));
            } else {
                i_lending.repayCorn(cornDebt);
                i_lending.withdrawCollateral(i_lending.s_userCollateral(address(this))); //withdraw remaing cuz of my weird rounding issues
                i_cornDEX.swap(i_corn.balanceOf(address(this)));
                // console.log ("-----END-----");
                break;
            }
            
            loops++;
            // console.log ("-----------END OF LOOP-----------");
        }
        emit LeveragedPositionClosed(msg.sender, loops);
    }

    /**
     * @notice Withdraw the ETH from the contract
     */
    function withdraw() public onlyOwner {
        uint256 balance = address(this).balance;
        require(balance > 0, "No balance to withdraw");
        (bool success, ) = payable(msg.sender).call{value: balance}("");
        require(success, "Failed to send Ether");
    }

    receive() external payable {}
}