// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.28;

/// Isolated single-node test registry, not production permissioned governance.
/// Read access is public; separate RPC connections are not authenticated readers.
contract RootRegistry {
    address public immutable writer;
    bytes32 public immutable scope;
    uint256 public immutable chain;
    uint64 public lastSequence;
    struct Roots { uint64 policyVersion; bytes32 policyRoot; bytes32 executionRoot; bytes32 bindingRoot; }
    mapping(uint64 => Roots) private records;

    constructor(address authorizedWriter, bytes32 expectedScope) {
        require(block.chainid == 2026112403, "private chain only");
        require(authorizedWriter != address(0), "writer missing");
        writer = authorizedWriter;
        scope = expectedScope;
        chain = block.chainid;
    }

    function commit(bytes32 expectedScope, uint64 sequence, uint64 policyVersion,
                    bytes32 policyRoot, bytes32 executionRoot, bytes32 bindingRoot) external {
        require(block.chainid == chain && msg.sender == writer, "unauthorized");
        require(expectedScope == scope, "wrong scope");
        require(sequence == lastSequence + 1 && policyVersion > 0, "invalid sequence/version");
        records[sequence] = Roots(policyVersion, policyRoot, executionRoot, bindingRoot);
        lastSequence = sequence;
    }

    function read(bytes32 expectedScope, uint64 sequence) external view
        returns (uint64, bytes32, bytes32, bytes32) {
        require(block.chainid == chain && expectedScope == scope, "wrong chain/scope");
        require(sequence > 0 && sequence <= lastSequence, "missing");
        Roots storage roots = records[sequence];
        return (roots.policyVersion, roots.policyRoot, roots.executionRoot, roots.bindingRoot);
    }
}
