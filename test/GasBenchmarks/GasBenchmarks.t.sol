// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import "forge-std/Test.sol";
import { BondRoute } from "@BondRoute/BondRoute.sol";
import { ExecutionData } from "@BondRoute/Core.sol";
import { IERC20, TokenAmount } from "@BondRouteProtected/BondRouteProtected.sol";
import { ERC20MockOZ } from "@test/mocks/ERC20MockOZ.sol";
import { MockProtocol, FundingTransfer } from "@test/mocks/MockProtocol.sol";

/**
 * @title GasBenchmarksTest
 * @notice Gas benchmarking tests for BondRoute operations
 * @dev Implements IGasBenchmarkTests from TestManifest.sol
 *
 * TESTING STRATEGY:
 * - Pure overhead tests: Measure ONLY BondRoute's gas cost (mock does nothing)
 * - Realistic tests: Measure end-to-end cost including protocol work (mock pulls funds)
 */
contract GasBenchmarksTest is Test {

    BondRoute public bondRoute;
    ERC20MockOZ public usdc_mock;
    ERC20MockOZ public dai_mock;
    IERC20 public usdc;
    IERC20 public dai;
    MockProtocol public mock_protocol;

    address public constant COLLECTOR  =  address(uint160(uint256(keccak256("COLLECTOR"))));
    address public constant USER       =  address(0x1111);
    address public constant RECIPIENT  =  address(0x2222);

    function setUp() public {
        bondRoute         =  new BondRoute( COLLECTOR );
        usdc_mock         =  new ERC20MockOZ( "USDC", "USDC", 6 );
        dai_mock          =  new ERC20MockOZ( "DAI", "DAI", 18 );
        usdc              =  IERC20(address(usdc_mock));
        dai               =  IERC20(address(dai_mock));
        mock_protocol     =  new MockProtocol();

        // Fund user
        usdc_mock.mint( USER, 1000000e6 );
        dai_mock.mint( USER, 1000000e18 );
        vm.deal( USER, 1000 ether );

        // Warm up BondRoute token balances (avoid zero-to-nonzero SSTORE)
        usdc_mock.mint( address(bondRoute), 1 );
        dai_mock.mint( address(bondRoute), 1 );

        // Approve
        vm.prank( USER );
        usdc_mock.approve( address(bondRoute), type(uint256).max );

        vm.prank( USER );
        dai_mock.approve( address(bondRoute), type(uint256).max );
    }


    // ━━━━  CORE OPERATIONS - PURE BONDROUTE OVERHEAD  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    function test_gas_create_bond_erc20() external {
        TokenAmount memory stake  =  TokenAmount({ token: usdc, amount: 100e6 });

        ExecutionData memory execution_data  =  ExecutionData({
            fundings:  new TokenAmount[](0),
            stake:     stake,
            salt:      12345,
            protocol:  mock_protocol,
            call:      abi.encodeWithSignature("test()")
        });

        bytes32 commitment_hash  =  bondRoute.__OFF_CHAIN__calc_commitment_hash( USER, execution_data );

        vm.prank( USER );
        uint256 gas_start  =  gasleft();
        bondRoute.create_bond( commitment_hash, stake );
        uint256 gas_used  =  gas_start - gasleft();

        console.log("Gas for create_bond (ERC20):  ", gas_used);

        // Reasonable bounds: ~60-80k (storage write + ERC20 transfer)
        assertLt( gas_used, 100000, "create_bond ERC20 should be under 100k gas" );
    }

    function test_gas_create_bond_native() external {
        TokenAmount memory stake  =  TokenAmount({ token: IERC20(address(0)), amount: 1 ether });

        ExecutionData memory execution_data  =  ExecutionData({
            fundings:  new TokenAmount[](0),
            stake:     stake,
            salt:      12345,
            protocol:  mock_protocol,
            call:      abi.encodeWithSignature("test()")
        });

        bytes32 commitment_hash  =  bondRoute.__OFF_CHAIN__calc_commitment_hash( USER, execution_data );

        vm.prank( USER );
        uint256 gas_start  =  gasleft();
        bondRoute.create_bond{ value: 1 ether }( commitment_hash, stake );
        uint256 gas_used  =  gas_start - gasleft();

        console.log("Gas for create_bond (native): ", gas_used);

        // Reasonable bounds: ~50-70k (storage write + native transfer)
        assertLt( gas_used, 100000, "create_bond native should be under 100k gas" );
    }

    function test_gas_execute_bond_minimal() external {
        // Setup: Create bond
        TokenAmount memory stake  =  TokenAmount({ token: usdc, amount: 100e6 });

        ExecutionData memory execution_data  =  ExecutionData({
            fundings:  new TokenAmount[](0),
            stake:     stake,
            salt:      12345,
            protocol:  mock_protocol,
            call:      abi.encodeWithSignature("test()")
        });

        bytes32 commitment_hash  =  bondRoute.__OFF_CHAIN__calc_commitment_hash( USER, execution_data );

        vm.prank( USER );
        bondRoute.create_bond( commitment_hash, stake );

        // Mock does NOTHING - pure BondRoute overhead
        mock_protocol.clear_funding_transfers();

        vm.roll( block.number + 1 );

        // Measure execute_bond with do-nothing protocol
        vm.prank( USER );
        uint256 gas_start  =  gasleft();
        bondRoute.execute_bond( execution_data );
        uint256 gas_used  =  gas_start - gasleft();

        console.log("Gas for execute_bond (minimal):", gas_used);

        // This measures PURE BondRoute overhead: validation + context setup + stake refund
        // Should be well under 100k
        assertLt( gas_used, 100000, "execute_bond minimal should be under 100k gas" );
    }

    function test_gas_execute_bond_with_funding() external {
        // Setup: Create bond with funding
        TokenAmount memory stake  =  TokenAmount({ token: usdc, amount: 100e6 });

        TokenAmount[] memory fundings  =  new TokenAmount[](1);
        fundings[ 0 ]  =  TokenAmount({ token: usdc, amount: 1000e6 });

        // Configure mock to PULL funds (realistic scenario)
        FundingTransfer[] memory transfers  =  new FundingTransfer[](1);
        transfers[ 0 ]  =  FundingTransfer({
            to:          RECIPIENT,
            token:       usdc,
            amount:      1000e6
        });
        mock_protocol.set_funding_transfers( transfers );

        ExecutionData memory execution_data  =  ExecutionData({
            fundings:  fundings,
            stake:     stake,
            salt:      12345,
            protocol:  mock_protocol,
            call:      abi.encodeWithSignature("test()")
        });

        bytes32 commitment_hash  =  bondRoute.__OFF_CHAIN__calc_commitment_hash( USER, execution_data );

        vm.prank( USER );
        bondRoute.create_bond( commitment_hash, stake );

        vm.roll( block.number + 1 );

        // Measure execute_bond with realistic funding pull
        vm.prank( USER );
        uint256 gas_start  =  gasleft();
        bondRoute.execute_bond( execution_data );
        uint256 gas_used  =  gas_start - gasleft();

        console.log("Gas for execute_bond (with funding):", gas_used);

        // Includes: BondRoute overhead + ERC20 transfer from user to recipient
        assertLt( gas_used, 150000, "execute_bond with funding should be under 150k gas" );
    }

    function test_gas_liquidate_single_bond() external {
        // Setup: Create expired bond
        TokenAmount memory stake  =  TokenAmount({ token: usdc, amount: 100e6 });

        ExecutionData memory execution_data  =  ExecutionData({
            fundings:  new TokenAmount[](0),
            stake:     stake,
            salt:      12345,
            protocol:  mock_protocol,
            call:      abi.encodeWithSignature("test()")
        });

        bytes32 commitment_hash  =  bondRoute.__OFF_CHAIN__calc_commitment_hash( USER, execution_data );

        uint256 valid_creation_timestamp_range  =  block.timestamp;

        vm.prank( USER );
        bondRoute.create_bond( commitment_hash, stake );

        // Warp past expiration (valid_creation_timestamp_range + MAX_BOND_LIFETIME = 111 days)
        vm.warp( valid_creation_timestamp_range + 111 days + 1 );

        bytes32[] memory commitment_hashes  =  new bytes32[](1);
        commitment_hashes[ 0 ]  =  commitment_hash;

        TokenAmount[] memory stakes  =  new TokenAmount[](1);
        stakes[ 0 ]  =  stake;

        // Measure liquidation
        vm.prank( COLLECTOR );
        uint256 gas_start  =  gasleft();
        bondRoute.liquidate_expired_bonds( commitment_hashes, stakes, COLLECTOR );
        uint256 gas_used  =  gas_start - gasleft();

        console.log("Gas for liquidate_single_bond:      ", gas_used);

        assertLt( gas_used, 100000, "liquidate single bond should be under 100k gas" );
    }

    function test_gas_liquidate_batch_10_bonds() external {
        // Setup: Create 10 expired bonds
        bytes32[] memory commitment_hashes  =  new bytes32[](10);
        TokenAmount[] memory stakes  =  new TokenAmount[](10);
        uint256 valid_creation_timestamp_range  =  block.timestamp;

        unchecked
        {
            for(  uint256 i = 0  ;  i < 10  ;  i++  )
            {
                TokenAmount memory stake  =  TokenAmount({ token: usdc, amount: 100e6 });

                ExecutionData memory execution_data  =  ExecutionData({
                    fundings:  new TokenAmount[](0),
                    stake:     stake,
                    salt:      12345 + i,
                    protocol:  mock_protocol,
                    call:      abi.encodeWithSignature("test()")
                });

                bytes32 commitment_hash  =  bondRoute.__OFF_CHAIN__calc_commitment_hash( USER, execution_data );

                vm.prank( USER );
                bondRoute.create_bond( commitment_hash, stake );

                commitment_hashes[ i ]  =  commitment_hash;
                stakes[ i ]             =  stake;
            }
        }

        // Warp past expiration (valid_creation_timestamp_range + MAX_BOND_LIFETIME = 111 days)
        vm.warp( valid_creation_timestamp_range + 111 days + 1 );

        // Measure batch liquidation
        vm.prank( COLLECTOR );
        uint256 gas_start  =  gasleft();
        bondRoute.liquidate_expired_bonds( commitment_hashes, stakes, COLLECTOR );
        uint256 gas_used  =  gas_start - gasleft();

        console.log("Gas for liquidate_batch_10_bonds:   ", gas_used);

        // Batch of 10 should be significantly more efficient per bond
        uint256 gas_per_bond  =  gas_used / 10;
        console.log("Gas per bond (batch):                ", gas_per_bond);

        assertLt( gas_used, 500000, "liquidate 10 bonds should be under 500k gas" );
    }


    // ━━━━  STORAGE OPTIMIZATIONS  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    function test_gas_bit_packing_effectiveness() external {
        // This test demonstrates that bit packing allows us to store
        // bond info in a single storage slot

        // Create a bond
        TokenAmount memory stake  =  TokenAmount({ token: usdc, amount: 100e6 });

        ExecutionData memory execution_data  =  ExecutionData({
            fundings:  new TokenAmount[](0),
            stake:     stake,
            salt:      12345,
            protocol:  mock_protocol,
            call:      abi.encodeWithSignature("test()")
        });

        bytes32 commitment_hash  =  bondRoute.__OFF_CHAIN__calc_commitment_hash( USER, execution_data );

        vm.prank( USER );
        bondRoute.create_bond( commitment_hash, stake );

        // Retrieve bond info - should only cost 1 SLOAD (2100 gas) + decoding
        uint256 gas_start  =  gasleft();
        bondRoute.__OFF_CHAIN__get_bond_info( commitment_hash, stake );
        uint256 gas_used  =  gas_start - gasleft();

        console.log("Gas for get_bond_info (1 slot read): ", gas_used);

        // Should be very cheap - just 1 SLOAD + minimal decoding
        // Without bit packing, would need 3-4 SLOADs (6300-8400 gas)
        assertLt( gas_used, 10000, "Bond info retrieval should be under 10k gas with bit packing" );
    }


    // ━━━━  OVERHEAD BENCHMARKS: PROTOCOL WARM VS COLD  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    function test_gas_overhead_zero_stake_protocol_warm() external {
        _measure_overhead({
            stake_type:     StakeType.ZERO,
            warm_protocol:  true
        });
    }

    function test_gas_overhead_zero_stake_protocol_cold() external {
        _measure_overhead({
            stake_type:     StakeType.ZERO,
            warm_protocol:  false
        });
    }

    function test_gas_overhead_native_stake_protocol_warm() external {
        _measure_overhead({
            stake_type:     StakeType.NATIVE,
            warm_protocol:  true
        });
    }

    function test_gas_overhead_native_stake_protocol_cold() external {
        _measure_overhead({
            stake_type:     StakeType.NATIVE,
            warm_protocol:  false
        });
    }

    function test_gas_overhead_erc20_stake_protocol_warm() external {
        _measure_overhead({
            stake_type:     StakeType.ERC20,
            warm_protocol:  true
        });
    }

    function test_gas_overhead_erc20_stake_protocol_cold() external {
        _measure_overhead({
            stake_type:     StakeType.ERC20,
            warm_protocol:  false
        });
    }


    // ━━━━  OVERHEAD MEASUREMENT HELPER  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    enum StakeType { ZERO, NATIVE, ERC20 }

    function _measure_overhead( StakeType stake_type, bool warm_protocol ) internal {
        mock_protocol.clear_funding_transfers();

        uint256 current_block  =  100;
        vm.roll( current_block );

        if(  warm_protocol  )
        {
            current_block  =  _warm_up_protocol( current_block );
        }

        TokenAmount memory stake;
        uint256 msg_value_create  =  0;

        if(  stake_type == StakeType.ZERO  )
        {
            stake  =  TokenAmount({ token: IERC20(address(0)), amount: 0 });
        }
        else if(  stake_type == StakeType.NATIVE  )
        {
            stake              =  TokenAmount({ token: IERC20(address(0)), amount: 1 ether });
            msg_value_create   =  1 ether;
        }
        else
        {
            stake  =  TokenAmount({ token: usdc, amount: 100e6 });
        }

        ExecutionData memory execution_data  =  ExecutionData({
            fundings:  new TokenAmount[](0),
            stake:     stake,
            salt:      current_block,
            protocol:  mock_protocol,
            call:      abi.encodeWithSignature("test()")
        });

        bytes32 commitment_hash  =  bondRoute.__OFF_CHAIN__calc_commitment_hash( USER, execution_data );

        current_block++;
        vm.roll( current_block );

        vm.prank( USER );
        uint256 gas_start_create  =  gasleft();
        bondRoute.create_bond{ value: msg_value_create }( commitment_hash, stake );
        uint256 gas_used_create  =  gas_start_create - gasleft();

        current_block++;
        vm.roll( current_block );

        vm.prank( USER );
        uint256 gas_start_execute  =  gasleft();
        bondRoute.execute_bond( execution_data );
        uint256 gas_used_execute  =  gas_start_execute - gasleft();

        uint256 total  =  gas_used_create + gas_used_execute;

        string memory stake_label  =  stake_type == StakeType.ZERO   ? "ZERO"   :
                                      stake_type == StakeType.NATIVE ? "NATIVE" : "ERC20";
        string memory temp_label   =  warm_protocol ? "WARM" : "COLD";

        console.log("");
        console.log("================================================================");
        console.log("OVERHEAD:", stake_label, "stake");
        console.log("PROTOCOL:", temp_label);
        console.log("================================================================");
        console.log("create_bond gas:  ", gas_used_create);
        console.log("execute_bond gas: ", gas_used_execute);
        console.log("----------------------------------------------------------------");
        console.log("TOTAL:            ", total);
        console.log("================================================================");
    }

    function _warm_up_protocol( uint256 start_block ) internal returns ( uint256 current_block ) {
        current_block  =  start_block;

        ExecutionData memory warmup_data  =  ExecutionData({
            fundings:  new TokenAmount[](0),
            stake:     TokenAmount({ token: IERC20(address(0)), amount: 0 }),
            salt:      999999,
            protocol:  mock_protocol,
            call:      abi.encodeWithSignature("test()")
        });

        bytes32 warmup_hash  =  bondRoute.__OFF_CHAIN__calc_commitment_hash( USER, warmup_data );

        current_block++;
        vm.roll( current_block );
        vm.prank( USER );
        bondRoute.create_bond( warmup_hash, warmup_data.stake );

        current_block++;
        vm.roll( current_block );
        vm.prank( USER );
        bondRoute.execute_bond( warmup_data );
    }


}
