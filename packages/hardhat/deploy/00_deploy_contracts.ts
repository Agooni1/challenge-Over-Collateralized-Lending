import { HardhatRuntimeEnvironment } from "hardhat/types";
import { DeployFunction } from "hardhat-deploy/types";
import { Contract } from "ethers";

/**
 * Deploys a contract named "YourContract" using the deployer account and
 * constructor arguments set to the deployer address
 *
 * @param hre HardhatRuntimeEnvironment object.
 */
const deployContracts: DeployFunction = async function (hre: HardhatRuntimeEnvironment) {
  /*
    On localhost, the deployer account is the one that comes with Hardhat, which is already funded.

    When deploying to live networks (e.g `yarn deploy --network sepolia`), the deployer account
    should have sufficient balance to pay for the gas fees for contract creation.

    You can generate a random account with `yarn generate` or `yarn account:import` to import your
    existing PK which will fill DEPLOYER_PRIVATE_KEY_ENCRYPTED in the .env file (then used on hardhat.config.ts)
    You can run the `yarn account` command to check your balance in every network.
  */
  const [deployer] = await hre.ethers.getSigners(); // deployer is a Signer, not a string
  const { deploy } = hre.deployments;

  await deploy("Corn", {
    from: deployer.address,
    // Contract constructor arguments
    args: [],
    log: true,
    // autoMine: can be passed to the deploy function to make the deployment process faster on local networks by
    // automatically mining the contract deployment transaction. There is no effect on live networks.
    autoMine: true,
  });
  const cornToken = await hre.ethers.getContract<Contract>("Corn", deployer.address);

  await deploy("CornDEX", {
    from: deployer.address,
    args: [cornToken.target],
    log: true,
    autoMine: true,
  });
  const cornDEX = await hre.ethers.getContract<Contract>("CornDEX", deployer.address);
  const lending = await deploy("Lending", {
    from: deployer.address,
    args: [cornDEX.target, cornToken.target],
    log: true,
    autoMine: true,
  });
  await deploy("FlashLoanLiquidator", {
    from: deployer.address,
    args: [cornDEX.target, cornToken.target, lending.address],
    log: true,
    autoMine: true,
  });

  // Set up the move price contract
  const movePrice = await deploy("MovePrice", {
    from: deployer.address,
    args: [cornDEX.target, cornToken.target],
    log: true,
    autoMine: true,
  });

  await deploy("Leverage", {
    from: deployer.address,
    args: [lending.address, cornDEX.target, cornToken.target],
    log: true,
    autoMine: true,
  });

  // Only set up contract state on local network
  if (hre.network.name == "localhost") {
    // Give ETH and CORN to the move price contract
    await hre.ethers.provider.send("hardhat_setBalance", [
      movePrice.address,
      `0x${hre.ethers.parseEther("10000000000000000000000").toString(16)}`,
    ]);
    await cornToken.mintTo(movePrice.address, hre.ethers.parseEther("10000000000000000000000"));
    // Lenders deposit CORN to the lending contract
    await cornToken.mintTo(lending.address, hre.ethers.parseEther("10000000000000000000000"));
    // Give CORN and ETH to the deployer
    await cornToken.mintTo(deployer.address, hre.ethers.parseEther("1000000000000"));
    await hre.ethers.provider.send("hardhat_setBalance", [
      deployer.address,
      `0x${hre.ethers.parseEther("100000000000").toString(16)}`,
    ]);

    await cornToken.approve(cornDEX.target, hre.ethers.parseEther("1000000000"));
    await cornDEX.init(hre.ethers.parseEther("1000000000"), { value: hre.ethers.parseEther("1000000") });

    //SCRIPT TO CREATE A LIQUIDATABLE POSITION
    // you can thank ChatGPT for this one (with a little tweaking from me)

    // 1. Create a new user (get a signer)
    const [, user] = await hre.ethers.getSigners();

    // 2. Fund the user with ETH
    await hre.ethers.provider.send("hardhat_setBalance", [
      user.address,
      `0x${hre.ethers.parseEther("100").toString(16)}`,
    ]);

    // 3. User deposits collateral (e.g., 1 ETH)
    const lendingInstance = await hre.ethers.getContractAt("Lending", lending.address, user);
    await lendingInstance.addCollateral({ value: hre.ethers.parseEther("1") });

    // 4. User borrows more CORN than allowed (to be liquidatable)
    // If collateral ratio is 120%, max safe borrow = (collateral * price) / 1.2
    // Let's borrow more than that (e.g., 1 CORN if price is 1)
    await lendingInstance.borrowCorn(hre.ethers.parseEther("833"));

    const movePriceInstance = await hre.ethers.getContractAt("MovePrice", movePrice.address, deployer);

    // Move the price down by swapping a large amount of ETH for CORN
    await movePriceInstance.movePrice(hre.ethers.parseEther("1000")); // Large positive value to drop price

    // Now, check if the user is liquidatable
    const isLiquidatable = await lendingInstance.isLiquidatable(user.address);
    console.log("User is liquidatable?", isLiquidatable);
  }
  //flashloan mintTo logic was giving an Owner error.
  //SRE challenge didn't mention having to change this so idk if im cheating
  //but like it was an Owner error pretty sure there's no way around it
  await cornToken.transferOwnership(lending.address);
};

export default deployContracts;
