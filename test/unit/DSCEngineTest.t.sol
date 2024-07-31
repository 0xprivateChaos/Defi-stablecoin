// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import {Test, console} from "forge-std/Test.sol";
import {DeployDSC} from "../../script/DeployDSC.s.sol";
import {DecentralizedStableCoin} from "../../src/DecentralizedStableCoin.sol";
import {DSCEngine} from "../../src/DSCEngine.sol";
import {HelperConfig} from "../../script/HelperConfig.s.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/ERC20Mock.sol";
import {MockFailedTransferFrom} from "../mocks/MockFailedTransferFrom.sol";
import {MockV3Aggregator} from "../mocks/MockV3Aggregator.sol";
import {MockFailedMintDSC} from "../mocks/MockFailedMintDSC.sol";
import {MockFailedTransfer} from "../mocks/MockFailedTransfer.sol";
import {MockMoreDebtDSC} from "../mocks/MockMoreDebtDSC.sol";

contract DSCEngineTest is Test {
    event CollateralRedeemed(address indexed redeemedFrom, address indexed redeemedTo, address indexed token, uint256 amount);

    DeployDSC deployer;
    DecentralizedStableCoin dsc;
    DSCEngine dscEngine;
    HelperConfig helperConfig;
    address ethUsdPriceFeed;
    address btcUsdPriceFeed;
    address weth;

    address public user = address(1);
    uint256 public amountCollateral = 10 ether;
    uint256 public amountToMint = 100 ether;

    // liquidation
    address public liquidator = makeAddr("liquidator");
    uint256 public collateralToCover = 20 ether;
    
    uint256 public constant STARTING_USER_BALANCE = 10 ether;

    function setUp() public {
        deployer = new DeployDSC();
        (dsc, dscEngine, helperConfig) = deployer.run();
        (ethUsdPriceFeed, btcUsdPriceFeed, weth,,) = helperConfig.activeNetworkConfig();
        if(block.chainid == 31337) {
            vm.deal(user, STARTING_USER_BALANCE);
        }
        ERC20Mock(weth).mint(user, STARTING_USER_BALANCE);
    }
    /////////////////////////
    //  Constructor Tests  //
    /////////////////////////
    address[] public tokenAddresses;
    address[] public priceFeedAddresses;

    function testRevertsIfTokenLengthDoesntMatchPriceFeeds() public {
        tokenAddresses.push(weth);
        priceFeedAddresses.push(ethUsdPriceFeed);
        priceFeedAddresses.push(btcUsdPriceFeed);

        vm.expectRevert(DSCEngine.DSCEngine__TokenAddressesAndPriceFeedAddressesMustBeSameLength.selector);
        new DSCEngine(tokenAddresses, priceFeedAddresses, address(dsc));
    }


    //////////////////////
    //  Price Tests     //
    //////////////////////

    function testGetUsdValue() public view {
        uint256 ethAmount = 15e18;
        // 15e16 * 2000 = 30,000e18
        uint256 expectedUsdValue = 30000e18;
        uint256 actualUsdValue = dscEngine.getUsdValue(weth, ethAmount);
        assertEq(actualUsdValue, expectedUsdValue);
    }

    function testGetTokenAmountFromUsd() public view {
        uint256 usdAmount = 100 ether;
        // 100e18 / 2000 = 0.05e18 ($2000 / ETH)
        uint256 expectedWeth = 0.05 ether;
        uint256 actualWeth = dscEngine.getTokenAmountFromUsd(weth, usdAmount);
        assertEq(actualWeth, expectedWeth);
    }

    ////////////////////////////////
    //  Deposit Collateral Tests  //
    ////////////////////////////////

    function testRevertsIfTransferFromFails() public {
        // Arrange - Setup
        address owner = msg.sender;
        vm.startPrank(owner);
        MockFailedTransferFrom mockDsc = new MockFailedTransferFrom();
        tokenAddresses = [address(mockDsc)];
        priceFeedAddresses = [ethUsdPriceFeed];
        DSCEngine mockDscEngine = new DSCEngine(tokenAddresses, priceFeedAddresses, address(mockDsc));
        mockDsc.mint(user, amountCollateral);
        mockDsc.transferOwnership(address(mockDscEngine));
        vm.stopPrank();

        // Arrange - User
        vm.startPrank(user);
        ERC20Mock(address(mockDsc)).approve(address(mockDscEngine), amountCollateral);
        // Act / Assert
        vm.expectRevert(DSCEngine.DSCEngine__TransferFailed.selector);
        mockDscEngine.depositCollateral(address(mockDsc), amountCollateral);
        vm.stopPrank();
    }

    function testRevertsIfCollateralIsZero() public {
        vm.startPrank(user);
        ERC20Mock(weth).approve(address(dscEngine), amountCollateral);

        vm.expectRevert(DSCEngine.DSCEngine__AmountMustBeMoreThanZero.selector);
        dscEngine.depositCollateral(weth, 0);
        vm.stopPrank();
    }

    function testRevertsWithUnapprovedCollateral() public {
        ERC20Mock randToken = new ERC20Mock("RAN", "RAN", user, amountCollateral);
        vm.startPrank(user);
        vm.expectRevert(DSCEngine.DSCEngine__TokenNotSupported.selector);
        dscEngine.depositCollateral(address(randToken), amountCollateral);
        vm.stopPrank();
    }

    modifier depositedCollateral() {
        vm.startPrank(user);
        ERC20Mock(weth).approve(address(dscEngine), amountCollateral);
        dscEngine.depositCollateral(weth, amountCollateral);
        vm.stopPrank();
        _;
    }

    function testCanDepositCollateralAndGetAccountInfo() public depositedCollateral {
        (uint256 totalDscMinted, uint256 collateralValueInUsd) = dscEngine.getAccountInformation(user);
        uint256 expectedTotalDscMinted = 0;
        uint256 expectedDepositAmount = dscEngine.getTokenAmountFromUsd(weth, collateralValueInUsd);
        assertEq(totalDscMinted, expectedTotalDscMinted);
        assertEq(amountCollateral, expectedDepositAmount);
    }

    ////////////////////////////////////////
    // depositCollateralAndMintDsc Tests  //
    ////////////////////////////////////////

    function testRevertsIfMintedDscBreaksHealthFactor() public {
        (, int256 price,,,) = MockV3Aggregator(ethUsdPriceFeed).latestRoundData();
        amountToMint = amountCollateral * (uint256(price) * 1e10) / 1e18;
        vm.startPrank(user);
        ERC20Mock(weth).approve(address(dscEngine), amountCollateral);

        uint256 expectedHealthFactor = dscEngine.calculateHealthFactor(amountToMint, dscEngine.getUsdValue(weth, amountCollateral));
        vm.expectRevert(abi.encodeWithSelector(DSCEngine.DSCEngine__BreaksHealthFactor.selector, expectedHealthFactor));
        dscEngine.depositCollateralAndMintDsc(weth, amountCollateral, amountToMint);
        vm.stopPrank();
    }

    function testCanDepositCollateralAndMintDscSuccessfully() public {
        vm.startPrank(user);
        ERC20Mock(weth).approve(address(dscEngine), amountCollateral);
        dscEngine.depositCollateralAndMintDsc(weth, amountCollateral, amountToMint);

        // Verify collateral deposit
        (uint256 totalDscMinted, uint256 collateralValueInUsd) = dscEngine.getAccountInformation(user);
        uint256 expectedDepositAmount = dscEngine.getTokenAmountFromUsd(weth, collateralValueInUsd);
        assertEq(amountCollateral, expectedDepositAmount);

        // Verify DSC minting
        assertEq(totalDscMinted, amountToMint);
        vm.stopPrank();
    }

    /////////////////////////
    //    mintDsc Tests    //
    /////////////////////////

    function testRevertsIfMintFails() public {
        // Arrange - Setup
        MockFailedMintDSC mockDsc = new MockFailedMintDSC();
        tokenAddresses = [weth];
        priceFeedAddresses = [ethUsdPriceFeed];
        DSCEngine mockDscEngine = new DSCEngine(tokenAddresses, priceFeedAddresses, address(mockDsc));
        mockDsc.transferOwnership(address(mockDscEngine));

        // Arrange - User
        vm.startPrank(user);
        ERC20Mock(weth).approve(address(mockDscEngine), amountCollateral);
        mockDscEngine.depositCollateral(weth, amountCollateral);
        
        // Act / Assert
        vm.expectRevert(DSCEngine.DSCEngine__MintFailed.selector);
        mockDscEngine.mintDsc(amountToMint);
        vm.stopPrank();
    }

    function testRevertsIfDscMintAmountBreaksHealthFactor() public depositedCollateral {
        (, int256 price,,,) = MockV3Aggregator(ethUsdPriceFeed).latestRoundData();
        amountToMint = amountCollateral * (uint256(price) * 1e10) / 1e18;
        vm.startPrank(user);
        uint256 expectedHealthFactor = dscEngine.calculateHealthFactor(amountToMint, dscEngine.getUsdValue(weth, amountCollateral));
        vm.expectRevert(abi.encodeWithSelector(DSCEngine.DSCEngine__BreaksHealthFactor.selector, expectedHealthFactor));
        dscEngine.mintDsc(amountToMint);
        vm.stopPrank();         
    }

    function testRevertsIfDscMintAmountIsZero() public {
        vm.startPrank(user);
        ERC20Mock(weth).approve(address(dscEngine), amountCollateral);
        dscEngine.depositCollateralAndMintDsc(weth, amountCollateral, amountToMint);
        vm.expectRevert(DSCEngine.DSCEngine__AmountMustBeMoreThanZero.selector);    
        dscEngine.mintDsc(0);
        vm.stopPrank();
    }

    function testCanMintDsc() public depositedCollateral {
        vm.startPrank(user);
        uint256 expectedTotalDscMinted = amountToMint;
        dscEngine.mintDsc(amountToMint);
        (uint256 totalDscMinted,) = dscEngine.getAccountInformation(user);
        assertEq(totalDscMinted, expectedTotalDscMinted);
    }

    /////////////////////////
    //    burnDsc Tests    //
    /////////////////////////

    function testRevertsIfDscBurnAmountIsZero() public {
        vm.startPrank(user);
        ERC20Mock(weth).approve(address(dscEngine), amountCollateral);
        dscEngine.depositCollateralAndMintDsc(weth, amountCollateral, amountToMint);
        vm.expectRevert(DSCEngine.DSCEngine__AmountMustBeMoreThanZero.selector);
        dscEngine.burnDsc(0);
        vm.stopPrank();
    }

    function testCantBurnMoreThanUserHas() public {
        vm.prank(user);
        vm.expectRevert();
        dscEngine.burnDsc(1);
    }

    function testCanBurnDsc() public {
        vm.startPrank(user);
        ERC20Mock(weth).approve(address(dscEngine), amountCollateral);
        dscEngine.depositCollateralAndMintDsc(weth, amountCollateral, amountToMint);
        uint256 burnAmount = amountToMint / 2;
        dsc.approve(address(dscEngine), burnAmount);
        dscEngine.burnDsc(burnAmount);
        (uint256 totalDscMinted,) = dscEngine.getAccountInformation(user);
        assertEq(totalDscMinted, amountToMint - burnAmount);    
        vm.stopPrank();
    }

    //////////////////////////////
    //  redeemCollateral Tests  //
    //////////////////////////////

    function testRevertsIfTransferFails() public {
        // Arrange - Setup
        MockFailedTransfer mockDsc = new MockFailedTransfer();
        tokenAddresses = [address(mockDsc)];
        priceFeedAddresses = [ethUsdPriceFeed];
        DSCEngine mockDscEngine = new DSCEngine(tokenAddresses, priceFeedAddresses, address(mockDsc));
        mockDsc.mint(user, amountCollateral);
        mockDsc.transferOwnership(address(mockDscEngine));

        // Arrange - User
        vm.startPrank(user);
        ERC20Mock(address(mockDsc)).approve(address(mockDscEngine), amountCollateral);
        mockDscEngine.depositCollateral(address(mockDsc), amountCollateral);
        
        // Act / Assert
        vm.expectRevert(DSCEngine.DSCEngine__TransferFailed.selector);
        mockDscEngine.redeemCollateral(address(mockDsc), amountCollateral);
        vm.stopPrank();
    }

    function testRevertsIfRedeemAmountIsZero() public {
        vm.startPrank(user);
        ERC20Mock(weth).approve(address(dscEngine), amountCollateral);
        dscEngine.depositCollateralAndMintDsc(weth, amountCollateral, amountToMint);
        vm.expectRevert(DSCEngine.DSCEngine__AmountMustBeMoreThanZero.selector);
        dscEngine.redeemCollateral(weth, 0);
        vm.stopPrank();
    }

    function testRedeemCollateralUpdatesBalanceCorrectly() public {
        vm.startPrank(user);
        ERC20Mock(weth).approve(address(dscEngine), amountCollateral);
        dscEngine.depositCollateralAndMintDsc(weth, amountCollateral, amountToMint);  
        uint256 amountToRedeem = amountCollateral / 2;
        dscEngine.redeemCollateral(weth, amountToRedeem);      
        uint256 remainingCollateral = dscEngine.getCollateralBalanceOfUser(user, weth);
        assertEq(remainingCollateral, amountCollateral - amountToRedeem);
        vm.stopPrank();
    }

    function testEmitCollateralRedeemedWithCorrectlyArgs() public depositedCollateral {
        vm.startPrank(user);
        vm.expectEmit(true, true, true, true, address(dscEngine));
        emit CollateralRedeemed(user, user, weth, amountCollateral);
        dscEngine.redeemCollateral(weth, amountCollateral);
        vm.stopPrank();
    }

    ////////////////////////////////////
    //  redeemCollateralForDSC Tests  //
    ////////////////////////////////////

    function testMustRedeemMoreThanZero() public {
        vm.startPrank(user);
        ERC20Mock(weth).approve(address(dscEngine), amountCollateral);
        dscEngine.depositCollateralAndMintDsc(weth, amountCollateral, amountToMint);
        dsc.approve(address(dscEngine), amountToMint);
        vm.expectRevert(DSCEngine.DSCEngine__AmountMustBeMoreThanZero.selector);
        dscEngine.redeemCollateralForDsc(weth, 0, amountToMint);
        vm.stopPrank();
    }

    function testCanRedeemDepositedCollateralForDsc() public {
        vm.startPrank(user);
        ERC20Mock(weth).approve(address(dscEngine), amountCollateral);
        dscEngine.depositCollateralAndMintDsc(weth, amountCollateral, amountToMint);
        dsc.approve(address(dscEngine), amountToMint);
        dscEngine.redeemCollateralForDsc(weth, amountCollateral, amountToMint);
        vm.stopPrank();

        uint256 userBalance = dsc.balanceOf(user);
        assertEq(userBalance, 0);
    }

    ///////////////////////////
    //  Health Factor Tests  //
    ///////////////////////////

    function testCalculateHealthFactorWithZeroDscMinted() public view {
        uint256 totalDscMinted = 0;
        uint256 collateralValueInUsd = 1000 * 1e18; // $1000
        uint256 expectedHealthFactor = type(uint256).max; // Infinity or max uint256
        uint256 healthFactor = dscEngine.calculateHealthFactor(totalDscMinted, collateralValueInUsd);
        assertEq(healthFactor, expectedHealthFactor);
    }

    modifier depositedCollateralAndMinted() {
        vm.startPrank(user);
        ERC20Mock(weth).approve(address(dscEngine), amountCollateral);
        dscEngine.depositCollateralAndMintDsc(weth, amountCollateral, amountToMint);
        vm.stopPrank();
        _;
    }

    function testHealthFactorGivesCorrectly() public depositedCollateralAndMinted {
        uint256 expectedHealthFactor = 100 ether;
        uint256 healthFactor = dscEngine.getHealthFactor(user);
        console.logUint(healthFactor);
        // $100 minted with $20,000 collateral at 50% liquidation threshold
        // means that we must have $200 collatareral at all times.
        // 20,000 * 0.5 = 10,000
        // 10,000 / 100 = 100 health factor
        assertEq(healthFactor, expectedHealthFactor);
    }

    function testHealthFactorCanBeBelowOne() public depositedCollateralAndMinted {
        int256 ethUsdUpdatedPriceFeed = 18e8; // 1ETH = $18
        MockV3Aggregator(ethUsdPriceFeed).updateAnswer(ethUsdUpdatedPriceFeed);
        uint256 expectedHealthFactor = 0.9 ether;
        uint256 healthFactor = dscEngine.getHealthFactor(user);
        console.logUint(healthFactor);
        assertEq(healthFactor, expectedHealthFactor);
    }

    ///////////////////////
    // Liquidation Tests //
    ///////////////////////

    function testMustImproveHealthFactorOnLiquidation() public {
        // Arrange - Setup
        MockMoreDebtDSC mockDsc = new MockMoreDebtDSC(ethUsdPriceFeed);
        tokenAddresses = [weth];
        priceFeedAddresses = [ethUsdPriceFeed];
        address owner = msg.sender;
        vm.prank(owner);
        DSCEngine mockDscEngine = new DSCEngine(tokenAddresses, priceFeedAddresses, address(mockDsc));
        mockDsc.transferOwnership(address(mockDscEngine));

        // Arrange - User
        vm.startPrank(user);
        ERC20Mock(weth).approve(address(mockDscEngine), amountCollateral);
        mockDscEngine.depositCollateralAndMintDsc(weth, amountCollateral, amountToMint);
        vm.stopPrank();

        // Arrange - Liquidator
        collateralToCover = 1 ether;
        ERC20Mock(weth).mint(liquidator, collateralToCover);

        vm.startPrank(liquidator);
        ERC20Mock(weth).approve(address(mockDscEngine), collateralToCover);
        uint256 debtToCover = 10 ether;
        mockDscEngine.depositCollateralAndMintDsc(weth, collateralToCover, amountToMint);
        mockDsc.approve(address(mockDscEngine), debtToCover);
        // Act
        int256 ethUsdUpdatedPrice = 18e8;
        MockV3Aggregator(ethUsdPriceFeed).updateAnswer(ethUsdUpdatedPrice);
        // Act / Assert
        vm.expectRevert(DSCEngine.DSCEngine__HealthFactorNotImproved.selector);
        mockDscEngine.liquidate(weth, user, debtToCover);
        vm.stopPrank();
    }

    function testCantLiquidateGoodHealthFactor() public depositedCollateralAndMinted {
        ERC20Mock(weth).mint(liquidator, collateralToCover);

        vm.startPrank(liquidator);
        ERC20Mock(weth).approve(address(dscEngine), collateralToCover);
        dscEngine.depositCollateralAndMintDsc(weth, collateralToCover, amountToMint);
        dsc.approve(address(dscEngine), amountToMint);
        vm.expectRevert(DSCEngine.DSCEngine__HealthFactorOk.selector);
        dscEngine.liquidate(weth, user, amountToMint);
        vm.stopPrank();
    }

    modifier liquidated() {
        vm.startPrank(user);
        ERC20Mock(weth).approve(address(dscEngine), amountCollateral);
        dscEngine.depositCollateralAndMintDsc(weth, amountCollateral, amountToMint);
        vm.stopPrank();

        int256 ethUsdUpdatedPrice = 18e8;
        MockV3Aggregator(ethUsdPriceFeed).updateAnswer(ethUsdUpdatedPrice);
        uint256 userHealthFactor = dscEngine.getHealthFactor(user);

        ERC20Mock(weth).mint(liquidator, collateralToCover);
        vm.startPrank(liquidator);
        ERC20Mock(weth).approve(address(dscEngine), collateralToCover);
        dscEngine.depositCollateralAndMintDsc(weth, collateralToCover, amountToMint);
        dsc.approve(address(dscEngine), amountToMint);
        dscEngine.liquidate(weth, user, amountToMint); // covering whole debt
        vm.stopPrank();
        _;
    }

    function testLiquidationPayoutIsCorrect() public liquidated {
        uint256 liquidatorWethBalance = ERC20Mock(weth).balanceOf(liquidator);
        uint256 expectedWeth = dscEngine.getTokenAmountFromUsd(weth, amountToMint) + dscEngine.getTokenAmountFromUsd(weth, amountToMint) / dscEngine.getLiquidationBonus();
        console.log(expectedWeth);
        assertEq(liquidatorWethBalance, expectedWeth);
    }

    function testUserStillHasSomeEthAfterLiquidation() public liquidated {
        uint256 amountLiquidated = dscEngine.getTokenAmountFromUsd(weth, amountToMint) + dscEngine.getTokenAmountFromUsd(weth, amountToMint) / dscEngine.getLiquidationBonus();

        uint256 usdAmountLiquidated = dscEngine.getUsdValue(weth, amountLiquidated);
        uint256 expectedUserCollateralValueInUsd = dscEngine.getUsdValue(weth, amountCollateral) - usdAmountLiquidated;
        console.log(expectedUserCollateralValueInUsd);
        (, uint256 collateralValueInUsd) = dscEngine.getAccountInformation(user);
        assertEq(collateralValueInUsd, expectedUserCollateralValueInUsd);
    }

    function testUserHasNoMoreDebt() public liquidated {
        (uint256 userDscMinted, ) = dscEngine.getAccountInformation(user);
        assertEq(userDscMinted, 0);
    }
}
