// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

/**
 * @title DSCEngine
 * @author 0xprivateChaos
 * 
 * The system is designed to be as minimal as possible, and have the tokens maintain a 1 token == $1 peg.
 * This stable coin has the properties:
 * - Exogenous Collateral
 * - Dollar pegged
 * - Algorithmically Stable
 * 
 * It is similar to the MakerDAO(DAI) system, but with a few key differences:
 * - no governance
 * - no fees
 * - only backed by WETH and WBTC
 * 
 * @notice This contract is the core of the DSC system. It handles all the logic for minting and redeemin DSC, as well as depositing and withdrawing collateral.
 * @notice This contract is VERY loosely based on the MakerDao DSS (DAI) system.
 */
contract DSCEngine {
    function depositCollateralAndMintDsc() external {}
    
    function redeemCollateralForDsc() external {}

    function burnDsc() external {}
}