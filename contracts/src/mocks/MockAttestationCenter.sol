// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {IAttestationCenter} from "../interfaces/IAttestationCenter.sol";
import {IAvsLogic} from "../interfaces/IAvsLogic.sol";

contract MockAttestationCenter is IAttestationCenter {
   address public avsLogic;
    
    function setAvsLogic(address _avsLogic) external {
        avsLogic = _avsLogic;
    }

    function submitPriceUpdate(address base, address quote, uint256 price) external {
        IAttestationCenter.TaskInfo memory task = IAttestationCenter.TaskInfo({
            proofOfTask: "",
            data: abi.encode(base, quote, price),
            taskPerformer: msg.sender,
            taskDefinitionId: 1
        });
        
        // Call afterTaskSubmission on AVS logic
        IAvsLogic(avsLogic).afterTaskSubmission(task, true, "", [uint256(0), uint256(0)], new uint256[](0));
    }
}
