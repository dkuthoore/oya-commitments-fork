// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "forge-std/Script.sol";

/// ------------------------
/// Minimal interfaces
/// ------------------------

interface ISafeProxyFactory {
    function createProxyWithNonce(
        address singleton,
        bytes memory initializer,
        uint256 saltNonce
    ) external returns (address proxy);
}

interface ISafe {
    function setup(
        address[] calldata _owners,
        uint256 _threshold,
        address to,
        bytes calldata data,
        address fallbackHandler,
        address paymentToken,
        uint256 payment,
        address payable paymentReceiver
    ) external;

    function nonce() external view returns (uint256);

    function getTransactionHash(
        address to,
        uint256 value,
        bytes calldata data,
        uint8 operation,
        uint256 safeTxGas,
        uint256 baseGas,
        uint256 gasPrice,
        address gasToken,
        address refundReceiver,
        uint256 _nonce
    ) external view returns (bytes32);

    function execTransaction(
        address to,
        uint256 value,
        bytes calldata data,
        uint8 operation,
        uint256 safeTxGas,
        uint256 baseGas,
        uint256 gasPrice,
        address gasToken,
        address payable refundReceiver,
        bytes calldata signatures
    ) external payable returns (bool success);
}

interface IModuleProxyFactory {
    function deployModule(
        address masterCopy,
        bytes calldata initializer,
        uint256 saltNonce
    ) external returns (address proxy);
}

/// ------------------------
/// Zodiac ModuleProxyFactory (tiny, self-contained)
/// Matches the deployModule pattern (CREATE2 + initializer call). :contentReference[oaicite:8]{index=8}
/// ------------------------
contract ModuleProxyFactory {
    event ModuleProxyCreation(address indexed proxy, address indexed masterCopy);

    error ZeroAddress(address target);
    error TakenAddress(address address_);
    error FailedInitialization();

    function createProxy(address target, bytes32 salt) internal returns (address result) {
        if (target == address(0)) revert ZeroAddress(target);
        bytes memory deployment = abi.encodePacked(
            hex"602d8060093d393df3363d3d373d3d3d363d73",
            target,
            hex"5af43d82803e903d91602b57fd5bf3"
        );
        assembly {
            result := create2(0, add(deployment, 0x20), mload(deployment), salt)
        }
        if (result == address(0)) revert TakenAddress(result);
    }

    function deployModule(address masterCopy, bytes memory initializer, uint256 saltNonce)
        public
        returns (address proxy)
    {
        proxy = createProxy(masterCopy, keccak256(abi.encodePacked(keccak256(initializer), saltNonce)));
        (bool success,) = proxy.call(initializer);
        if (!success) revert FailedInitialization();
        emit ModuleProxyCreation(proxy, masterCopy);
    }
}

contract DeploySafeWithOptimisticGovernor is Script {
    // Safe tx operation enum
    uint8 internal constant OP_CALL = 0;

    function run() external {
        // ---------
        // Required
        // ---------
        uint256 DEPLOYER_PK = vm.envUint("DEPLOYER_PK");

        // ------------
        // Addresses (override these per network)
        // ------------
        address SAFE_SINGLETON = vm.envOr(
            "SAFE_SINGLETON",
            address(0xd9Db270c1B5E3Bd161E8c8503c55cEABeE709552) // Safe v1.3.0 singleton :contentReference[oaicite:9]{index=9}
        );

        address SAFE_PROXY_FACTORY = vm.envOr(
            "SAFE_PROXY_FACTORY",
            address(0xa6B71E26C5e0845f74c812102Ca7114b6a896AB2) // Safe v1.3.0 proxy factory :contentReference[oaicite:10]{index=10}
        );

        address SAFE_FALLBACK_HANDLER = vm.envOr(
            "SAFE_FALLBACK_HANDLER",
            address(0xf48f2B2d2a534e402487b3ee7c18c33Aec0Fe5e4) // CompatibilityFallbackHandler 1.3.0 :contentReference[oaicite:11]{index=11}
        );

        // UMA OptimisticGovernor mastercopy (mainnet). Override on other chains.
        address OG_MASTER_COPY = vm.envOr(
            "OG_MASTER_COPY",
            address(0x28CeBFE94a03DbCA9d17143e9d2Bd1155DC26D5d) // :contentReference[oaicite:12]{index=12}
        );

        // ------------
        // Governance params
        // ------------
        address COLLATERAL = vm.envAddress("OG_COLLATERAL"); // must be UMA-whitelisted or setUp will revert :contentReference[oaicite:13]{index=13}
        uint256 BOND_AMOUNT = vm.envUint("OG_BOND_AMOUNT");
        uint64 LIVENESS = uint64(vm.envOr("OG_LIVENESS", uint256(2 days))); // seconds
        string memory RULES = vm.envString("OG_RULES");

        // Identifier (bytes32). Default "ZODIAC" (commonly used for OG). :contentReference[oaicite:14]{index=14}
        string memory IDENTIFIER_STR = vm.envOr("OG_IDENTIFIER_STR", string("ZODIAC"));
        bytes32 IDENTIFIER = bytes32(bytes(IDENTIFIER_STR)); // "ZODIAC" fits in 32 bytes.

        // salts
        uint256 SAFE_SALT_NONCE = vm.envOr("SAFE_SALT_NONCE", uint256(1));
        uint256 OG_SALT_NONCE = vm.envOr("OG_SALT_NONCE", uint256(1));

        // safe owners config (script is designed for 1-owner bootstrap so it can auto-exec enableModule)
        // You can later rotate owners/threshold via a Safe tx or by proposing through OG.
        address deployer = vm.addr(DEPLOYER_PK);
        address;
        owners[0] = deployer;
        uint256 threshold = 1;

        vm.startBroadcast(DEPLOYER_PK);

        // 1) Deploy (or use) ModuleProxyFactory
        //    (You can also set MODULE_PROXY_FACTORY env and skip deployment if you prefer.)
        address MODULE_PROXY_FACTORY = vm.envOr("MODULE_PROXY_FACTORY", address(0));
        if (MODULE_PROXY_FACTORY == address(0)) {
            ModuleProxyFactory mpf = new ModuleProxyFactory();
            MODULE_PROXY_FACTORY = address(mpf);
        }

        // 2) Deploy Safe proxy
        bytes memory safeInitializer = abi.encodeWithSelector(
            ISafe.setup.selector,
            owners,
            threshold,
            address(0), // to
            bytes(""),  // data
            SAFE_FALLBACK_HANDLER,
            address(0), // paymentToken
            0,          // payment
            payable(address(0)) // paymentReceiver
        );

        address safeProxy = ISafeProxyFactory(SAFE_PROXY_FACTORY).createProxyWithNonce(
            SAFE_SINGLETON,
            safeInitializer,
            SAFE_SALT_NONCE
        );

        // 3) Deploy OptimisticGovernor instance (as module proxy) and initialize via setUp(bytes)
        // setUp decodes: (owner, collateral, bondAmount, rules, identifier, liveness) :contentReference[oaicite:16]{index=16}
        bytes memory ogInitParams = abi.encode(
            safeProxy,
            COLLATERAL,
            BOND_AMOUNT,
            RULES,
            IDENTIFIER,
            LIVENESS
        );

        bytes memory ogInitializerCall = abi.encodeWithSignature(
            "setUp(bytes)",
            ogInitParams
        );

        address ogModule = IModuleProxyFactory(MODULE_PROXY_FACTORY).deployModule(
            OG_MASTER_COPY,
            ogInitializerCall,
            OG_SALT_NONCE
        );

        // 4) Enable the module on the Safe by executing a Safe tx:
        // Safe.enableModule(ogModule) must be called by the Safe itself, so we execTransaction.
        bytes memory enableModuleCalldata = abi.encodeWithSignature(
            "enableModule(address)",
            ogModule
        );

        ISafe safe = ISafe(safeProxy);
        uint256 safeNonce = safe.nonce();

        bytes32 txHash = safe.getTransactionHash(
            safeProxy,                 // to = safe itself
            0,                        // value
            enableModuleCalldata,     // data
            OP_CALL,                  // operation
            0, 0, 0,                  // safeTxGas, baseGas, gasPrice
            address(0),               // gasToken
            address(0),               // refundReceiver
            safeNonce
        );

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(DEPLOYER_PK, txHash);
        bytes memory sig = abi.encodePacked(r, s, v);

        bool ok = safe.execTransaction(
            safeProxy,
            0,
            enableModuleCalldata,
            OP_CALL,
            0, 0, 0,
            address(0),
            payable(address(0)),
            sig
        );
        require(ok, "enableModule execTransaction failed");

        vm.stopBroadcast();

        console2.log("=== Deployed ===");
        console2.log("ModuleProxyFactory:", MODULE_PROXY_FACTORY);
        console2.log("Safe:", safeProxy);
        console2.log("OptimisticGovernor module:", ogModule);
        console2.logBytes32("Identifier(bytes32):", IDENTIFIER);
        console2.logUint("Bond amount:", BOND_AMOUNT);
        console2.logUint("Liveness(seconds):", uint256(LIVENESS));
    }
}
