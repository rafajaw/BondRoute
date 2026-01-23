// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

/*

        ██████╗  ██████╗ ███╗   ██╗██████╗ ██████╗  ██████╗ ██╗   ██╗████████╗███████╗
        ██╔══██╗██╔═══██╗████╗  ██║██╔══██╗██╔══██╗██╔═══██╗██║   ██║╚══██╔══╝██╔════╝
        ██████╔╝██║   ██║██╔██╗ ██║██║  ██║██████╔╝██║   ██║██║   ██║   ██║   █████╗
        ██╔══██╗██║   ██║██║╚██╗██║██║  ██║██╔══██╗██║   ██║██║   ██║   ██║   ██╔══╝
        ██████╔╝╚██████╔╝██║ ╚████║██████╔╝██║  ██║╚██████╔╝╚██████╔╝   ██║   ███████╗
        ╚═════╝  ╚═════╝ ╚═╝  ╚═══╝╚═════╝ ╚═╝  ╚═╝ ╚═════╝  ╚═════╝    ╚═╝   ╚══════╝
        ━━━━━━━━━━━━━━━━━━━━━━━━━━━  trustless fair play  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━

*/

import { Collector } from "./Collector.sol";

/**
 * @title BondRoute
 * @notice Main BondRoute contract - minimal entry point
 * @dev Inherits complete layered architecture: Storage -> Core -> Signing -> User -> Provider -> Collector -> BondRoute
 */
contract BondRoute is Collector {

    /**
     * @notice Initialize BondRoute with collector
     * @param collector Address that will liquidate expired bonds
     *
     * @dev ERROR CODES:
     *      - `Invalid(string field, uint256 value)` if `collector` is zero address
     */
    constructor( address collector )
    Collector( collector ) { }

    /**
     * @notice Returns the domain separator for EIP-712 signature verification
     * @dev Standard EIP-712 interface
     */
    function DOMAIN_SEPARATOR( )
    external view returns ( bytes32 )
    {
        return _domainSeparatorV4( );
    }

    /**
     * @notice Reject accidental native token deposits
     */
    receive( )
    external  payable
    {
        revert( "Direct transfers not allowed" );
    }
}