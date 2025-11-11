// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

// From yearn-strategy submodule (adjust path if needed)
import {BaseStrategy} from "../yearn-strategy/src/BaseStrategy.sol";  // Yearn's tokenized strategy base

contract EmpowerToursYieldStrategy is Initializable, UUPSUpgradeable, OwnableUpgradeable, BaseStrategy {
    using SafeERC20 for IERC20;

    // Staking positions linked to NFTs
    struct StakingPosition {
        address nftAddress; // PassportNFT or MusicLicenseNFT
        uint256 nftTokenId;
        address owner;
        uint256 depositTime;
        uint256 stakedAmount;
        bool active;
    }

    IERC20 public asset; // TOURS token
    address public constant AAVE_POOL = 0x7d2768dE32b0b80b7a3454c06BdAc94A69DDc7A9; // Update for Monad/Aave port
    mapping(uint256 => StakingPosition) public stakingPositions;
    mapping(address => uint256[]) public userPositions;
    uint256 public positionCounter;

    // Constructor disabled for upgradeable
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    // Initializer for UUPS
    function initialize(
        address _asset,
        string memory _name,
        address _management,
        address _keeper,
        address _emergencyAdmin,
        address _donationAddress,
        address _tokenizedStrategyAddress
    ) external initializer {
        __UUPSUpgradeable_init();
        __OwnableUpgradeable_init();
        __BaseStrategy_init(_asset, _name, _management, _keeper, _emergencyAdmin, _donationAddress, _tokenizedStrategyAddress);  // Yearn init
        asset = IERC20(_asset);
        asset.safeApprove(AAVE_POOL, type(uint256).max);
    }

    // Stake TOURS with NFT collateral
    function stakeWithNFT(
        address nftAddress,
        uint256 nftTokenId,
        uint256 toursAmount
    ) external returns (uint256 positionId) {
        require(toursAmount > 0, "Amount must be > 0");
        require(IERC721(nftAddress).ownerOf(nftTokenId) == msg.sender, "Not NFT owner");

        asset.safeTransferFrom(msg.sender, address(this), toursAmount);

        positionId = positionCounter++;
        stakingPositions[positionId] = StakingPosition({
            nftAddress: nftAddress,
            nftTokenId: nftTokenId,
            owner: msg.sender,
            depositTime: block.timestamp,
            stakedAmount: toursAmount,
            active: true
        });
        userPositions[msg.sender].push(positionId);

        _deployFunds(toursAmount);
    }

    // Get position details
    function getPosition(uint256 positionId) external view returns (StakingPosition memory) {
        return stakingPositions[positionId];
    }

    // Get user's positions
    function getUserPositions(address user) external view returns (uint256[] memory) {
        return userPositions[user];
    }

    // Get total value for user (for credit scoring)
    function getPortfolioValue(address user) external view returns (uint256 totalValue) {
        uint256[] memory positions = userPositions[user];
        for (uint i = 0; i < positions.length; i++) {
            StakingPosition memory pos = stakingPositions[positions[i]];
            if (pos.active) {
                uint256 timeElapsed = block.timestamp - pos.depositTime;
                uint256 yearsElapsed = (timeElapsed * 1e18) / (365 days);
                uint256 estimatedYield = (pos.stakedAmount * 4 * yearsElapsed) / (100 * 1e18);
                totalValue += pos.stakedAmount + estimatedYield;
            }
        }
    }

    // Deploy funds to Aave (override from BaseStrategy)
    function _deployFunds(uint256 _amount) internal override {
        (bool success, ) = AAVE_POOL.call(
            abi.encodeWithSignature("supply(address,uint256,address,uint16)", address(asset), _amount, address(this), 0)
        );
        require(success, "Aave supply failed");
    }

    // Free funds from Aave (override)
    function _freeFunds(uint256 _amount) internal override {
        (bool success, ) = AAVE_POOL.call(
            abi.encodeWithSignature("withdraw(address,uint256,address)", address(asset), _amount, address(this))
        );
        require(success, "Aave withdraw failed");
    }

    // Report current value (CRITICAL FOR YIELD) - override
    function _harvestAndReport() internal override returns (uint256 _totalAssets) {
        address aToken = getAaveATokenAddress(address(asset));
        uint256 aTokenBalance = IERC20(aToken).balanceOf(address(this));
        uint256 idleBalance = asset.balanceOf(address(this));
        _totalAssets = aTokenBalance + idleBalance;

        // OCTANT MAGIC: Calculate profit, mint shares, send to dragonRouter for allocation
        // (Implement directional routing here, e.g., to event pools)
    }

    // Check deposit capacity (override)
    function availableDepositLimit(address) public view override returns (uint256) {
        return type(uint256).max;  // Unlimited for MVP
    }

    // Utility: Get Aave aToken
    function getAaveATokenAddress(address _asset) internal view returns (address aToken) {
        // In production: Use Aave data provider interface
        // Hardcode for testnet or implement query
        aToken = address(0);  // Placeholder - update with actual
    }

    // UUPS: Authorize upgrades
    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}
}
