pragma solidity 0.8.19;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "openzeppelin/token/ERC20/IERC20.sol";
import "compound-protocol/contracts/WhitePaperInterestRateModel.sol";
import "compound-protocol/contracts/CErc20Delegator.sol";
import "compound-protocol/contracts/CErc20Delegate.sol";
import "compound-protocol/contracts/Comptroller.sol";
import "compound-protocol/contracts/Unitroller.sol";
import "compound-protocol/contracts/SimplePriceOracle.sol";
import "compound-protocol/contracts/PriceOracle.sol";
import "../src/AaveFlashLoanLiquidate.sol";
import "forge-std/console.sol";

contract FlashLoanLiquidateTest is Test {
    address admin;
    address user1;
    address user2;
    address constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address constant UNI = 0x1f9840a85d5aF5bf1D1762F925BDADdC4201F984;
    AaveFlashLoanLiquidate aaveFlashLoanLiquidate;
    // compound arguments -------
    CErc20Delegator cUSDCDelegator;
    CErc20Delegator cUNIDelegator;
    WhitePaperInterestRateModel interestRateModelUSDC;
    WhitePaperInterestRateModel interestRateModelUNI;
    CErc20Delegate cUSDCDelegate;
    CErc20Delegate cUNIDelegate;
    // oracle
    SimplePriceOracle oracle;
    // every cToken use the same comptroller
    Comptroller comptroller;
    Unitroller unitroller;
    // 
    Comptroller comptrollerProxy;
    CErc20 cUSDC;
    CErc20 cUNI;
    // --------------------------

    function setUp() public {
        // fork mainnet at block 17465000
        string memory rpc = vm.envString("MAINNET_RPC_URL");
        vm.createSelectFork(rpc, 17465000);

        user1 = makeAddr("user1");
        user2 = makeAddr("user2");
        admin = makeAddr("admin");
        
        vm.startPrank(admin);
        // compound setup ----------------------------------------------
        // Comptroller and Unitroller
        // Must be admin to create comptroller and unitroller
        comptroller = new Comptroller();
        unitroller = new Unitroller();
        uint errorCode = unitroller._setPendingImplementation(address(comptroller));
        require(errorCode == 0, "failed to set pendingImplementation");
        comptroller._become(unitroller);
        
        // oracle
        oracle = new SimplePriceOracle();
        Comptroller(address(unitroller))._setPriceOracle(PriceOracle(oracle));

        // InterestRateModel -> use WhitePaperInterestRateModel, 0% rate
        interestRateModelUSDC = new WhitePaperInterestRateModel(0, 0);
        interestRateModelUNI = new WhitePaperInterestRateModel(0, 0);

        // implementation_ -> CErc20Delegate
        cUSDCDelegate = new CErc20Delegate();
        cUNIDelegate = new CErc20Delegate();

        // set cERC20Delegators
        cUSDCDelegator = new CErc20Delegator(
            USDC,
            ComptrollerInterface(address(unitroller)),
            InterestRateModel(address(interestRateModelUSDC)),
            10**6,// 10**(18 + USDC_decimals - cUSDC_decimals)
            "Compound USDC",
            "cUSDC",
            18,
            payable(admin),
            address(cUSDCDelegate),
            ''
        );

        cUNIDelegator = new CErc20Delegator(
            UNI,
            ComptrollerInterface(address(unitroller)),
            InterestRateModel(address(interestRateModelUNI)),
            10**18,// 10**(18 + UNI_decimals - cUNI_decimals)
            "Compound Uniswap",
            "cUNI",
            18,
            payable(admin),
            address(cUNIDelegate),
            ''
        );

        comptrollerProxy = Comptroller(address(unitroller));
        cUSDC = CErc20(address(cUSDCDelegator));
        cUNI = CErc20(address(cUNIDelegator));

        // put cUSDC and cUNI on the market
        comptrollerProxy._supportMarket(CToken(address(cUSDCDelegator)));
        comptrollerProxy._supportMarket(CToken(address(cUNIDelegator)));

        // set price for UNI and USDC
        // The price of the asset in USD as an unsigned integer 
        // scaled up by 10 ^ (36 - underlying asset decimals). 
        // E.g. WBTC has 8 decimal places, so the return value is scaled up by 1e28.
        oracle.setUnderlyingPrice(CToken(address(cUSDC)), 1 * 10**30);
        oracle.setUnderlyingPrice(CToken(address(cUNI)), 5 * 10**18);

        // admin set CloseFactor = 50%
        assertEq(
            comptrollerProxy._setCloseFactor(0.5 * 10**18),
            0 // no error
        );
        // admin set LiquidationIncentive = 8%
        assertEq(
            // notice that this should be 108% 
            comptrollerProxy._setLiquidationIncentive(1.08 * 10**18),
            0 // no error
        );
        // admin set cUNI collateralFactor to 50%
        assertEq(
            comptrollerProxy._setCollateralFactor(CToken(address(cUNI)),0.5 * 10**18),
            0 // no error
        );
        // compound setup end ------------------------------------------
        vm.stopPrank(); // admin

        aaveFlashLoanLiquidate = new AaveFlashLoanLiquidate();
        vm.label(address(comptrollerProxy), "comptrollerProxy");
        vm.label(address(cUSDC), "cUSDC");
        vm.label(address(cUNI), "cUNI");
        vm.label(USDC, "USDC");
        vm.label(UNI, "UNI");
        vm.label(address(aaveFlashLoanLiquidate), "aaveFlashLoanLiquidate");
    }

    function testLiquidateByAaveFlashloan() public {
        uint256 collateralAmount = 1000 * 10**18;
        uint256 borrowAmount = 2500 * 10**6; // usdc decimals = 6

        // user2 deposit 2500 USDC, user1 will borrow later
        vm.startPrank(user2);
        deal(USDC, user2, borrowAmount);
        IERC20(USDC).approve(address(cUSDC), borrowAmount);
        cUSDC.mint(borrowAmount);
        assertEq(cUSDC.balanceOf(user2), 2500 * 10**cUSDC.decimals());
        vm.stopPrank(); // user2

        // give user1 1000 UNI
        deal(UNI, user1, collateralAmount);
        vm.startPrank(user1);
        IERC20(UNI).approve(address(cUNI), collateralAmount);
        cUNI.mint(collateralAmount);
        assertEq(cUNI.balanceOf(user1), collateralAmount);
        
        // user1 add cUNI to collateral
        address[] memory collacterals = new address[](1);
        collacterals[0] = address(cUNI);
        comptrollerProxy.enterMarkets(collacterals);
        uint256 liquidity;
        uint256 shortfall;
        (, liquidity, shortfall) = comptrollerProxy.getAccountLiquidity(user1);
        assertEq(liquidity, 2500 * 10**18);

        // user1 borrow USDC
        cUSDC.borrow(borrowAmount);
        assertEq(IERC20(USDC).balanceOf(user1), borrowAmount);
        (, liquidity, shortfall) = comptrollerProxy.getAccountLiquidity(user1);
        (,,uint borrowBalance, uint exchangeRate) = cUSDC.getAccountSnapshot(user1);
        vm.stopPrank(); // user1

        // set price of UNI to $4
        oracle.setUnderlyingPrice(CToken(address(cUNI)), 4 * 10**18);
        // user1 shortfall should be greater than 0 now
        (, liquidity, shortfall) = comptrollerProxy.getAccountLiquidity(user1);
        assertGt(shortfall, 0);

        // liquidate by aave flashloan
        aaveFlashLoanLiquidate.flashLoanLiquidate(
            address(this),
            USDC,
            borrowAmount/2 , // close factor = 50%
            address(cUSDC),
            user1,
            address(cUNI),
            UNI
        );
        
        assertGt(IERC20(USDC).balanceOf(address(this)), 0);
        console.log(IERC20(USDC).balanceOf(address(this))); // 63638693
    }
}