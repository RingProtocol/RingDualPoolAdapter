// SPDX-License-Identifier: MIT
pragma solidity ^0.8.21;

/// @notice Minimal interfaces for the Ring Protocol FewToken wrapping layer.
/// @dev The adapter verifies the wrapper through both `token()` and the canonical factory mapping.
interface IFewFactory {
    /// @return wrapper Canonical FewToken for `originalToken`, or address(0) if none exists.
    function getWrappedToken(address originalToken) external view returns (address wrapper);
}

interface IFewWrappedToken {
    /// @notice Underlying token reported by the wrapper.
    function token() external view returns (address originalToken);
    /// @notice Pull `amount` underlying from caller, mint fwToken to `to`.
    function wrapTo(uint256 amount, address to) external returns (uint256 wrappedAmount);
    /// @notice Burn `amount` fwToken from caller, send underlying to `to`.
    function unwrapTo(uint256 amount, address to) external returns (uint256 unwrappedAmount);
}
