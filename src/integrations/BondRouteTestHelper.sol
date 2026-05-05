// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import { Test } from "forge-std/Test.sol";

import { BondRoute } from "../BondRoute.sol";
import { BONDROUTE_ADDRESS } from "./BondRouteProtected.sol";


/**
 * @title BondRouteTestHelper
 * @notice Foundry helper for making BondRouteProtected's hardcoded BondRoute address available in tests.
 */
abstract contract BondRouteTestHelper is Test {

    string internal constant BONDROUTE_ARTIFACT  =  "BondRoute.sol:BondRoute";
    address internal constant BONDROUTE_COLLECTOR  =  address(0x8FEcd09e19889E52FEae817684C6e478767139a2);

    BondRoute internal bond_route;


    function _set_up_bond_route( ) internal returns ( BondRoute )
    {
        if(  BONDROUTE_ADDRESS.code.length == 0  )
        {
            deployCodeTo( BONDROUTE_ARTIFACT, abi.encode( BONDROUTE_COLLECTOR ), BONDROUTE_ADDRESS );
        }

        bond_route  =  BondRoute(payable(BONDROUTE_ADDRESS));
        return bond_route;
    }
}
