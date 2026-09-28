// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "./V1ReviewBase.sol";

/// FLIP-307 (FLIP-302 G5): an owner moves a live mandate to a new agent key
/// with one amendment. The app's "Move to the new key" flow relies on these
/// contract facts; production code is unchanged.
contract V1AgentMoveTest is V1ReviewBase {
    address internal newAgent = address(0xA6F);

    function _bind(address token) internal returns (MockFeed feed) {
        feed = new MockFeed();
        feed.set(7, 1e8, vm.getBlockTimestamp(), 7);
        IDescriptors.Descriptor memory d;
        d.kind = IDescriptors.DescriptorKind.PerAddress;
        d.target = address(feed);
        d.selector = MockFeed.latestRoundData.selector;
        d.subjectArg = -1;
        d.word = 1;
        d.isSigned = true;
        d.mustBePositive = true;
        d.freshness = IDescriptors.Freshness.ChainlinkRound;
        d.maxAge = 3600;
        d.gasStipend = 160_000;
        d.copyBytes = 160;
        bytes32 id = registry.listDescriptor(d);
        registry.setPriceRound(token, id, address(feed));
    }

    function _route100() internal view returns (bytes memory) {
        return _route(_swap(address(asset), 100e18, principal));
    }

    function _fireAs(address who, bytes32 id, bytes memory route) internal returns (uint256) {
        vm.prank(who);
        return core.fire(id, 100e18, route);
    }

    function _blocked(bytes32 id, IShieldV1.MandateReason reason) internal {
        vm.expectRevert(abi.encodeWithSelector(IShieldV1.MandateBlocked.selector, id, reason));
    }

    function test_moveKeepsTheMandateAndOnlyTheNewAgentFires() public {
        _bind(address(asset));
        IShieldV1.MandateParams memory p = _genericParams(generic.ACTION_TRANSFORM(), _genericConfig());
        bytes32 id = _register(p);
        bytes memory route = _route100();
        assertEq(_fireAs(agent, id, route), 100e18);
        uint256 usedBefore = core.getMandate(id).cumulativeUsed;

        p.agent = newAgent;
        vm.prank(principal);
        core.amendMandate(id, p);

        assertEq(core.getMandate(id).agent, newAgent);
        assertEq(core.getMandate(id).revision, 2);
        assertEq(core.getMandate(id).cumulativeUsed, usedBefore, "spent so far survives the move");
        assertEq(core.getMandate(id).firings, 1, "firings survive the move");

        _blocked(id, IShieldV1.MandateReason.NOT_AGENT);
        _fireAs(agent, id, route);
        assertEq(_fireAs(newAgent, id, route), 100e18);
        assertEq(core.getMandate(id).firings, 2);
    }

    function test_ownerCanMoveWhileTheOldAgentIsFrozen() public {
        _bind(address(asset));
        IShieldV1.MandateParams memory p = _genericParams(generic.ACTION_TRANSFORM(), _genericConfig());
        bytes32 id = _register(p);
        bytes memory route = _route100();
        vm.prank(enforcer);
        registry.freezeAgent(agent);
        _blocked(id, IShieldV1.MandateReason.AGENT_FROZEN);
        _fireAs(agent, id, route);

        p.agent = newAgent;
        vm.prank(principal);
        core.amendMandate(id, p);
        assertEq(_fireAs(newAgent, id, route), 100e18);
    }

    function test_theContractAcceptsAFrozenNewAgentSoTheAppMustCheck() public {
        _bind(address(asset));
        IShieldV1.MandateParams memory p = _genericParams(generic.ACTION_TRANSFORM(), _genericConfig());
        bytes32 id = _register(p);
        vm.prank(enforcer);
        registry.freezeAgent(newAgent);
        p.agent = newAgent;
        vm.prank(principal);
        core.amendMandate(id, p); // no frozen check on the new agent
        bytes memory route = _route100();
        _blocked(id, IShieldV1.MandateReason.AGENT_FROZEN);
        _fireAs(newAgent, id, route);
    }

    function test_onlyThePrincipalMovesAndNeverToItself() public {
        IShieldV1.MandateParams memory p = _genericParams(generic.ACTION_TRANSFORM(), _genericConfig());
        bytes32 id = _register(p);
        p.agent = newAgent;
        vm.prank(agent);
        vm.expectRevert(IShieldV1.NotPrincipal.selector);
        core.amendMandate(id, p);
        p.agent = principal;
        vm.prank(principal);
        vm.expectRevert(abi.encodeWithSelector(IShieldV1.InvalidParams.selector, bytes32("agent")));
        core.amendMandate(id, p);
    }
}
