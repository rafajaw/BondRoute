// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

error Reentrancy( );

/**
 * @title ReentrancyLock
 * @notice Reentrancy guard with bitmask allowlist pattern.
 *
 * @dev *WARNING*  -  Relies on transient storage (EIP-1153). Chains without EIP-1153 support will panic.
 *
 * @dev Each function declares which lock it holds and which other locks may call it.
 *      Reverts if the function reenters itself or is called from a disallowed context.
 *
 *      Example locks:
 *          uint256 constant ALLOW_NONE  =  0;
 *          uint256 constant DEPOSIT     =  1 << 0;
 *          uint256 constant WITHDRAW    =  1 << 1;
 *          uint256 constant TRANSFER    =  1 << 2;
 *
 *      Example usage:
 *          lockAndAllow( DEPOSIT, ALLOW_NONE )                 // Acquires DEPOSIT. Reverts if any lock is held.
 *          lockAndAllow( WITHDRAW, DEPOSIT )                   // Acquires WITHDRAW. Only callable from DEPOSIT.
 *          lockAndAllow(  TRANSFER,  DEPOSIT | WITHDRAW  )     // Acquires TRANSFER. Callable from DEPOSIT or WITHDRAW.
 *          lockAndAllow(  DEPOSIT | WITHDRAW,  ALLOW_NONE  )   // Acquires both DEPOSIT and WITHDRAW at once.
 */
abstract contract ReentrancyLock {

    uint256 private transient __transient__lock_state;

    /**
     * @param lock Lock bits to acquire. Can be one or more locks ORed together.
     * @param allow Locks that are permitted to already be held when entering this function.
     */
    modifier lockAndAllow( uint256 lock, uint256 allow )
    {
        uint256 state  =  __transient__lock_state;
        if(  state & (lock | ~allow)  !=  0  )  revert Reentrancy( );

        __transient__lock_state  =  state | lock;

        _;

        __transient__lock_state  =  state;
    }

    /**
     * @dev Same check as lockAndAllow but does not acquire any lock. For view functions.
     */
    modifier lockAndAllowView( uint256 lock, uint256 allow )
    {
        if(  __transient__lock_state & (lock | ~allow)  !=  0  )  revert Reentrancy( );

        _;
    }
}
