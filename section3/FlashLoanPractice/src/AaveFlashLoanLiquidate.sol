pragma solidity 0.8.19;

import {IERC20} from "openzeppelin/token/ERC20/IERC20.sol";
import {
  IFlashLoanSimpleReceiver,
  IPoolAddressesProvider,
  IPool
} from "aave-v3-core/contracts/flashloan/interfaces/IFlashLoanSimpleReceiver.sol";
import { CErc20 } from "compound-protocol/contracts/CErc20.sol";
import { CTokenInterface } from "compound-protocol/contracts/CTokenInterfaces.sol";
import "v3-periphery/interfaces/ISwapRouter.sol";

contract AaveFlashLoanLiquidate is IFlashLoanSimpleReceiver{
  address constant POOL_ADDRESSES_PROVIDER = 0x2f39d218133AFaB8F2B819B1066c7E434Ad94E9e;
  address constant swapRouter = 0xE592427A0AEce92De3Edee1F18E0157C05861564;
  struct LiquidateData {
    address cErc20;
    address borrower;
    address collacteral;
    address liquidator;
    address collacteralToken;
  }

  function flashLoanLiquidate(
    address liquidator, 
    address asset, 
    uint256 amount, 
    address cErc20,
    address borrower,
    address collacteral,
    address collacteralToken
    ) external {
      // use struct to avoid stack too deep
      LiquidateData memory data;
      data.cErc20 = cErc20;
      data.borrower = borrower;
      data.collacteral = collacteral;
      data.liquidator = liquidator;
      data.collacteralToken = collacteralToken;
      bytes memory param = abi.encode(data);
      POOL().flashLoanSimple(
        address(this),
        asset,
        amount,
        param,   // bytes calldata params,
        0       // uint16 referralCode
      );
  }

  function executeOperation(
    address asset,
    uint256 amount,
    uint256 premium,
    address initiator,
    bytes calldata params
  ) external returns (bool){
    // liquidate at Compound
    (LiquidateData memory data) = abi.decode(params, (LiquidateData));
    IERC20(asset).approve(data.cErc20, amount);
    CErc20(data.cErc20).liquidateBorrow(data.borrower, amount, CTokenInterface(data.collacteral));
    // redeem cToken to token (cUNI -> UNI)
    CErc20(data.collacteral).redeem(CErc20(data.collacteral).balanceOf(address(this)));

    // swap token for asset (UNI -> USDC)
    IERC20(data.collacteralToken).approve(swapRouter, IERC20(data.collacteralToken).balanceOf(address(this)));
    ISwapRouter.ExactInputSingleParams memory swapParams =
    ISwapRouter.ExactInputSingleParams({
      tokenIn: data.collacteralToken,
      tokenOut: asset,
      fee: 3000, // 0.3%
      recipient: address(this),
      deadline: block.timestamp,
      amountIn: IERC20(data.collacteralToken).balanceOf(address(this)),
      amountOutMinimum: 0,
      sqrtPriceLimitX96: 0
    });
    // The call to `exactInputSingle` executes the swap.
    // swap Router = 0xE592427A0AEce92De3Edee1F18E0157C05861564
    uint256 amountOut = ISwapRouter(swapRouter).exactInputSingle(swapParams);
    uint256 paybackPool = amount + premium;
    // approve POOL to take our debt back
    IERC20(asset).approve(address(POOL()), paybackPool);

    // send profit
    uint256 profit = IERC20(asset).balanceOf(address(this)) - amount - premium;
    IERC20(asset).transfer(data.liquidator, profit);

    return true;
  }

  function ADDRESSES_PROVIDER() public view returns (IPoolAddressesProvider) {
    return IPoolAddressesProvider(POOL_ADDRESSES_PROVIDER);
  }

  function POOL() public view returns (IPool) {
    return IPool(ADDRESSES_PROVIDER().getPool());
  }
}