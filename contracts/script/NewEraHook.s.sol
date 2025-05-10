// SPDX-License-Identifier: UNLICENSED
pragma solidity >=0.8.20;

/*______     __      __                              __      __ 
 /      \   /  |    /  |                            /  |    /  |
/$$$$$$  | _$$ |_   $$ |____    ______   _______   _$$ |_   $$/   _______ 
$$ |  $$ |/ $$   |  $$      \  /      \ /       \ / $$   |  /  | /       |
$$ |  $$ |$$$$$$/   $$$$$$$  |/$$$$$$  |$$$$$$$  |$$$$$$/   $$ |/$$$$$$$/ 
$$ |  $$ |  $$ | __ $$ |  $$ |$$    $$ |$$ |  $$ |  $$ | __ $$ |$$ |
$$ \__$$ |  $$ |/  |$$ |  $$ |$$$$$$$$/ $$ |  $$ |  $$ |/  |$$ |$$ \_____ 
$$    $$/   $$  $$/ $$ |  $$ |$$       |$$ |  $$ |  $$  $$/ $$ |$$       |
 $$$$$$/     $$$$/  $$/   $$/  $$$$$$$/ $$/   $$/    $$$$/  $$/  $$$$$$$/
*/
/**
 * @author Othentic Labs LTD.
 * @notice Terms of Service: https://www.othentic.xyz/terms-of-service
 */
import {Script, console} from "forge-std/Script.sol";
import {NewEraHook} from "../src/NewEraHook.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {HookMiner} from "v4-periphery/src/utils/HookMiner.sol";
import {console} from "forge-std/console.sol";

// How to:
// Either `source ../../.env` or replace variables in command.
// forge script script/NewEraHook.s.sol --via-ir --rpc-url https://base-sepolia.infura.io/v3/86d6db8b43814247b322f75d29ba345e --private-key 151ee9c063332f97069f4f2833c32878a3e35a77070869fae3c0c6050c055528 --broadcast -vvvv --verify --etherscan-api-key 86d6db8b43814247b322f75d29ba345e --chain 84532 --verifier-url https://base-sepolia.etherscan.io/ --sig="run(address,address,uint256)" 0x822BFc76e35C8bCcCeb5e10aC429F7EcE10D3416 0x05E73354cFDd6745C338b50BcFDfA3Aa6fA03408 1000
contract NewEraHookDeploy is Script {
    function setUp() public {}

    function run(address attestationCenter, address poolManager,  uint256 _expirationInterval) public {
        // https://book.getfoundry.sh/guides/deterministic-deployments-using-create2?highlight=CREATE2_DEPLOY#deterministic-deployments-using-create2
        address CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;

        uint160 flags = uint160(
            Hooks.BEFORE_SWAP_FLAG | 
            Hooks.AFTER_INITIALIZE_FLAG | 
            Hooks.AFTER_SWAP_FLAG |
            Hooks.BEFORE_INITIALIZE_FLAG |
            Hooks.BEFORE_ADD_LIQUIDITY_FLAG 
        );
        bytes memory constructorArgs = abi.encode(address(attestationCenter), IPoolManager(address(poolManager)), _expirationInterval);

        (address hookAddress, bytes32 salt) =
            HookMiner.find(CREATE2_DEPLOYER, flags, type(NewEraHook).creationCode, constructorArgs);

        console.log("Mined hook address:", hookAddress);
        console.log("Salt:", vm.toString(salt));

        vm.startBroadcast();
        // NewEraHook avsHook = new NewEraHook{salt: salt}(address(attestationCenter), IPoolManager(address(poolManager)), _expirationInterval);

        // require(address(avsHook) == hookAddress, "Hook address mismatch");

        // IAttestationCenter(attestationCenter).setAvsLogic(address(avsHook));
        vm.stopBroadcast();
    }
}
// forge script script/NewEraHook.s.sol --via-ir --rpc-url https://base-sepolia.infura.io/v3/86d6db8b43814247b322f75d29ba345e --private-key 151ee9c063332f97069f4f2833c32878a3e35a77070869fae3c0c6050c055528 --broadcast -vvvv --verify --etherscan-api-key 86d6db8b43814247b322f75d29ba345e --chain 84532 --verifier-url https://base-sepolia.etherscan.io/ --optimize --optimizer-runs 20 --sig="run(address,address,uint256)" 0x822BFc76e35C8bCcCeb5e10aC429F7EcE10D3416 0x05E73354cFDd6745C338b50BcFDfA3Aa6fA03408 1000