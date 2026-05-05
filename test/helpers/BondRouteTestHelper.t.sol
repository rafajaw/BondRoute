// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import { BondRoute } from "@BondRoute/BondRoute.sol";
import { BONDROUTE_ADDRESS } from "@BondRouteProtected/BondRouteProtected.sol";
import { BondRouteTestHelper } from "@BondRouteProtected/BondRouteTestHelper.sol";


contract BondRouteTestHelperTest is BondRouteTestHelper {

    function test_set_up_bond_route_deploys_to_hardcoded_address( )
    public
    {
        BondRoute deployed  =  _set_up_bond_route( );

        assertEq( address(deployed), BONDROUTE_ADDRESS, "BondRoute should be deployed at the hardcoded address." );
        assertGt( address(deployed).code.length, 0, "BondRoute code should exist at the hardcoded address." );
        assertEq( deployed.get_collector( ), BONDROUTE_COLLECTOR, "BondRoute should use the production collector." );
        assertTrue( deployed.DOMAIN_SEPARATOR( ) != bytes32(0), "BondRoute EIP-712 domain should be initialized." );
    }
}
