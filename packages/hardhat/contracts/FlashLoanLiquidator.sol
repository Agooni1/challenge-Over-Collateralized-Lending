// SPDX-License-Identifier: UNLICENSED
// import "hardhat/console.sol";
import "./Lending.sol";

contract FlashLoanLiquidator {
    Corn i_corn;
    CornDEX i_cornDEX;
    Lending i_lending;

    constructor(address _cornDEX, address _corn, address _lending) {
        i_cornDEX = CornDEX(_cornDEX);
        i_corn = Corn(_corn);
        i_lending = Lending(_lending);
        i_corn.approve(address(this), type(uint256).max);
        i_corn.approve(address(i_lending), type(uint256).max);
    }

    function executeOperation(uint256 _amount, address _initiator, address _extraParam) external returns (bool) {
        // console.log('before liquidate balance:', i_corn.balanceOf(address(this)));
        // i_corn.approve(address(i_lending), _amount);
        i_lending.liquidate(_extraParam);
        // console.log('after liquidate balance:', i_corn.balanceOf(address(this)));
        // console.log("actual ETH balance:", address(this).balance);

        uint256 xReserves = address(i_cornDEX).balance;
        uint256 yReserves = i_corn.balanceOf(address(i_cornDEX));
        uint256 Ethneeded = i_cornDEX.calculateXInput(_amount, xReserves, yReserves);

        i_cornDEX.swap{value: Ethneeded}(Ethneeded);
        // console.log("after swap CORN balance:", i_corn.balanceOf(address(this)));
        // console.log("after swap ETH balance:", address(this).balance);

        // i_corn.transfer(msg.sender, i_corn.balanceOf(address(this)) - _amount);
        // console.log("iniitiator:");
        // console.logAddress(_initiator);

        // (bool success, ) = payable(_initiator).call{value: address(this).balance}("");
        // if (!success) {
        //     revert Lending__TransferFailed();
        // }

        // you what maybe im not so smart, the initial initiater/msg.sender is no longer my wallet but the contract itself
        // so I guess I'd have to either call flashloan myself and and implment the final payable transfer or i can just implement
        // a seperate withdraw function and do the whole Ownable thing

        return true;
    }

    //SRE given workflow weirdly manual and annoying to do. Just do it here idk y not
    function liquidate( address user) external {
        uint256 _amount = i_lending.s_userBorrowed(user);
        // console.log("balance before flashloan:", i_corn.balanceOf(address(this)));
        // console.log("amount:", _amount);
        i_lending.flashLoan(IFlashLoanRecipient(address(this)), _amount, user);
        // console.log("balance after flashloan:", i_corn.balanceOf(address(this)));
    }

    receive() external payable {}
}