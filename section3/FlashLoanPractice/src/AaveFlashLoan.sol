pragma solidity 0.8.19;

import {IERC20} from "openzeppelin/token/ERC20/IERC20.sol";
import {BalanceChecker} from "./BalanceChecker.sol";
import {
  IFlashLoanSimpleReceiver,
  IPoolAddressesProvider,
  IPool
} from "aave-v3-core/contracts/flashloan/interfaces/IFlashLoanSimpleReceiver.sol";

// TODO: Inherit IFlashLoanSimpleReceiver
contract AaveFlashLoan is IFlashLoanSimpleReceiver{
  address constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
  address constant POOL_ADDRESSES_PROVIDER = 0x2f39d218133AFaB8F2B819B1066c7E434Ad94E9e;

  function execute(BalanceChecker checker) external {
    bytes memory param = abi.encode(address(checker));
    // TODO
    // 1. call pool flashloan simple
    POOL().flashLoanSimple(
    address(this),        // receiverAddress,
    USDC,                 // address asset,
    10_000_000 * 10 ** 6, // uint256 amount,
    param,                // bytes calldata params,
    0                    // uint16 referralCode
    ); 
  }

  function executeOperation(
    address asset,
    uint256 amount,
    uint256 premium,
    address initiator,
    bytes calldata params
  ) external returns (bool){
    address checker = abi.decode(params,(address));
    BalanceChecker(checker).checkBalance();
    IERC20(asset).approve(address(POOL()), amount + premium);
    return true;
  }

  function ADDRESSES_PROVIDER() public view returns (IPoolAddressesProvider) {
    return IPoolAddressesProvider(POOL_ADDRESSES_PROVIDER);
  }

  function POOL() public view returns (IPool) {
    return IPool(ADDRESSES_PROVIDER().getPool());
  }
}
