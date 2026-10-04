// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

/// @notice Base for the misbehaving tokens below: plain balances, no allowances.
abstract contract BaseToken {
    mapping(address => uint256) public balanceOf;

    function mint(address to, uint256 value) external {
        balanceOf[to] += value;
    }

    function _move(address from, address to, uint256 value) internal virtual {
        require(balanceOf[from] >= value, "balance");
        balanceOf[from] -= value;
        balanceOf[to] += value;
    }
}

/// @notice Burns 1% of every transfer (fee-on-transfer).
contract FeeToken is BaseToken {
    function transfer(address to, uint256 value) external returns (bool) {
        _move(msg.sender, to, value);
        return true;
    }

    function transferFrom(address from, address to, uint256 value) external returns (bool) {
        _move(from, to, value);
        return true;
    }

    function _move(address from, address to, uint256 value) internal override {
        uint256 fee = value / 100;
        require(balanceOf[from] >= value, "balance");
        balanceOf[from] -= value;
        balanceOf[to] += value - fee;
    }
}

/// @notice USDT-style: transfer functions return nothing.
contract NoReturnToken is BaseToken {
    function transfer(address to, uint256 value) external {
        _move(msg.sender, to, value);
    }

    function transferFrom(address from, address to, uint256 value) external {
        _move(from, to, value);
    }
}

/// @notice Returns false instead of reverting, and moves nothing.
contract FalseToken is BaseToken {
    function transfer(address, uint256) external pure returns (bool) {
        return false;
    }

    function transferFrom(address, address, uint256) external pure returns (bool) {
        return false;
    }
}

/// @notice Calls back into `hook` on every transfer, like an ERC-777 recipient
///         hook, and records whether the callback succeeded.
contract HookToken is BaseToken {
    address public hook;
    bytes public hookData;
    bool public reentered;
    bool public reentrySucceeded;

    function setHook(address target, bytes calldata data) external {
        hook = target;
        hookData = data;
    }

    function transfer(address to, uint256 value) external returns (bool) {
        _move(msg.sender, to, value);
        _callHook();
        return true;
    }

    function transferFrom(address from, address to, uint256 value) external returns (bool) {
        _callHook();
        _move(from, to, value);
        return true;
    }

    function _callHook() internal {
        if (hook == address(0) || reentered) return;
        reentered = true;
        (reentrySucceeded,) = hook.call(hookData);
    }
}

/// @notice Lets the HookToken re-enter the registry as a principal.
contract Reenterer {
    /// Reverts if the inner call reverts, so HookToken.reentrySucceeded is meaningful.
    function call(address target, bytes calldata data) external {
        (bool ok,) = target.call(data);
        require(ok, "inner call reverted");
    }
}
