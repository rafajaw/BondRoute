// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import { MockProtocol } from "./MockProtocol.sol";
import { BondContext } from "@BondRouteProtected/BondRouteProtected.sol";
import { Reentrancy } from "@BondRoute/utils/ReentrancyLock.sol";

/**
 * @title MockProtocolReentrant
 * @notice MockProtocol with reentrancy attack capabilities for testing
 * @dev Separate from MockProtocol to avoid adding gas overhead to benchmarks
 */
contract MockProtocolReentrant is MockProtocol {

    address private _reentrancy_target;
    bytes private _reentrancy_call;
    bool private _reentrancy_enabled;
    bool private _did_reentrancy_succeed;

    function set_reentrancy_call( address target, bytes calldata call ) external
    {
        _reentrancy_target   =  target;
        _reentrancy_call     =  call;
        _reentrancy_enabled  =  true;
        _did_reentrancy_succeed  =  false;
    }

    function did_reentrancy_succeed( ) external view returns ( bool )
    {
        return _did_reentrancy_succeed;
    }

    function clear_reentrancy( ) external
    {
        _reentrancy_target   =  address(0);
        _reentrancy_call     =  "";
        _reentrancy_enabled  =  false;
        _did_reentrancy_succeed  =  false;
    }

    function _execute_reentrancy_attack( ) private
    {
        _reentrancy_enabled  =  false;

        ( bool success, bytes memory revertdata )  =  _reentrancy_target.call( _reentrancy_call );
        if(  success == true  ||  bytes4(revertdata) != Reentrancy.selector  )
        {
            _did_reentrancy_succeed  =  true;
        }
    }

    function BondRoute_entry_point( bytes calldata call, BondContext memory context ) public override returns ( bytes memory output )
    {
        if(  _reentrancy_enabled  )
        {
            _execute_reentrancy_attack();
        }

        // Call parent implementation
        return super.BondRoute_entry_point( call, context );
    }
}
