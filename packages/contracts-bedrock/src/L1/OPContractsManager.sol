// SPDX-License-Identifier: MIT
pragma solidity 0.8.15;

// Contracts
import { OPContractsBase } from "src/L1/OPContractsBase.sol";

// Libraries
import { Blueprint } from "src/libraries/Blueprint.sol";
import { Constants } from "src/libraries/Constants.sol";
import { Bytes } from "src/libraries/Bytes.sol";
import { Claim, Hash, Duration, GameType, GameTypes, OutputRoot } from "src/dispute/lib/Types.sol";

// Interfaces
import { IResourceMetering } from "interfaces/L1/IResourceMetering.sol";
import { IBigStepper } from "interfaces/dispute/IBigStepper.sol";
import { IDelayedWETH } from "interfaces/dispute/IDelayedWETH.sol";
import { IAnchorStateRegistry } from "interfaces/dispute/IAnchorStateRegistry.sol";
import { IDisputeGame } from "interfaces/dispute/IDisputeGame.sol";
import { IAddressManager } from "interfaces/legacy/IAddressManager.sol";
import { IProxyAdmin } from "interfaces/universal/IProxyAdmin.sol";
import { IDelayedWETH } from "interfaces/dispute/IDelayedWETH.sol";
import { IDisputeGameFactory } from "interfaces/dispute/IDisputeGameFactory.sol";
import { IFaultDisputeGame } from "interfaces/dispute/IFaultDisputeGame.sol";
import { IPermissionedDisputeGame } from "interfaces/dispute/IPermissionedDisputeGame.sol";
import { ISuperchainConfig } from "interfaces/L1/ISuperchainConfig.sol";
import { IProtocolVersions } from "interfaces/L1/IProtocolVersions.sol";
import { IOptimismPortal2 } from "interfaces/L1/IOptimismPortal2.sol";
import { ISystemConfig } from "interfaces/L1/ISystemConfig.sol";
import { IL1CrossDomainMessenger } from "interfaces/L1/IL1CrossDomainMessenger.sol";
import { IL1ERC721Bridge } from "interfaces/L1/IL1ERC721Bridge.sol";
import { IL1StandardBridge } from "interfaces/L1/IL1StandardBridge.sol";
import { IOptimismMintableERC20Factory } from "interfaces/universal/IOptimismMintableERC20Factory.sol";

contract OPContractsManager is OPContractsBase {
    // -------- Constants and Variables --------

    /// @custom:semver 1.0.0-beta.35
    function version() public pure virtual returns (string memory) {
        return "1.0.0-beta.35";
    }

    constructor(
        ISuperchainConfig _superchainConfig,
        IProtocolVersions _protocolVersions,
        string memory _l1ContractsRelease,
        Blueprints memory _blueprints,
        Implementations memory _implementations,
        address _upgradeController
    ) {
        assertValidContractAddress(address(_superchainConfig));
        assertValidContractAddress(address(_protocolVersions));
        superchainConfig = _superchainConfig;
        protocolVersions = _protocolVersions;
        L1_CONTRACTS_RELEASE = _l1ContractsRelease;

        blueprint = _blueprints;
        implementation = _implementations;
        upgradeController = _upgradeController;
    }

    // -------- Events --------

    /// @notice Emitted when a new OP Stack chain is deployed.
    /// @param l2ChainId Chain ID of the new chain.
    /// @param deployer Address that deployed the chain.
    /// @param deployOutput ABI-encoded output of the deployment.
    event Deployed(uint256 indexed l2ChainId, address indexed deployer, bytes deployOutput);

    /// @notice Emitted when a chain is upgraded
    /// @param systemConfig Address of the chain's SystemConfig contract
    /// @param upgrader Address that initiated the upgrade
    event Upgraded(uint256 indexed l2ChainId, ISystemConfig indexed systemConfig, address indexed upgrader);

    // -------- Methods --------

    function deploy(DeployInput calldata _input) external virtual returns (DeployOutput memory) {
        assertValidInputs(_input);
        uint256 l2ChainId = _input.l2ChainId;
        string memory saltMixer = _input.saltMixer;
        DeployOutput memory output;

        // -------- Deploy Chain Singletons --------

        // The ProxyAdmin is the owner of all proxies for the chain. We temporarily set the owner to
        // this contract, and then transfer ownership to the specified owner at the end of deployment.
        // The AddressManager is used to store the implementation for the L1CrossDomainMessenger
        // due to it's usage of the legacy ResolvedDelegateProxy.
        output.addressManager = IAddressManager(
            Blueprint.deployFrom(
                blueprint.addressManager, computeSalt(l2ChainId, saltMixer, "AddressManager"), abi.encode()
            )
        );
        output.opChainProxyAdmin = IProxyAdmin(
            Blueprint.deployFrom(
                blueprint.proxyAdmin, computeSalt(l2ChainId, saltMixer, "ProxyAdmin"), abi.encode(address(this))
            )
        );
        output.opChainProxyAdmin.setAddressManager(output.addressManager);

        // -------- Deploy Proxy Contracts --------

        // Deploy ERC-1967 proxied contracts.
        output.l1ERC721BridgeProxy =
            IL1ERC721Bridge(deployProxy(l2ChainId, output.opChainProxyAdmin, saltMixer, "L1ERC721Bridge"));
        output.optimismPortalProxy =
            IOptimismPortal2(payable(deployProxy(l2ChainId, output.opChainProxyAdmin, saltMixer, "OptimismPortal")));
        output.systemConfigProxy =
            ISystemConfig(deployProxy(l2ChainId, output.opChainProxyAdmin, saltMixer, "SystemConfig"));
        output.optimismMintableERC20FactoryProxy = IOptimismMintableERC20Factory(
            deployProxy(l2ChainId, output.opChainProxyAdmin, saltMixer, "OptimismMintableERC20Factory")
        );
        output.disputeGameFactoryProxy =
            IDisputeGameFactory(deployProxy(l2ChainId, output.opChainProxyAdmin, saltMixer, "DisputeGameFactory"));
        output.anchorStateRegistryProxy =
            IAnchorStateRegistry(deployProxy(l2ChainId, output.opChainProxyAdmin, saltMixer, "AnchorStateRegistry"));

        // Deploy legacy proxied contracts.
        output.l1StandardBridgeProxy = IL1StandardBridge(
            payable(
                Blueprint.deployFrom(
                    blueprint.l1ChugSplashProxy,
                    computeSalt(l2ChainId, saltMixer, "L1StandardBridge"),
                    abi.encode(output.opChainProxyAdmin)
                )
            )
        );
        output.opChainProxyAdmin.setProxyType(address(output.l1StandardBridgeProxy), IProxyAdmin.ProxyType.CHUGSPLASH);
        string memory contractName = "OVM_L1CrossDomainMessenger";
        output.l1CrossDomainMessengerProxy = IL1CrossDomainMessenger(
            Blueprint.deployFrom(
                blueprint.resolvedDelegateProxy,
                computeSalt(l2ChainId, saltMixer, "L1CrossDomainMessenger"),
                abi.encode(output.addressManager, contractName)
            )
        );
        output.opChainProxyAdmin.setProxyType(
            address(output.l1CrossDomainMessengerProxy), IProxyAdmin.ProxyType.RESOLVED
        );
        output.opChainProxyAdmin.setImplementationName(address(output.l1CrossDomainMessengerProxy), contractName);
        // Now that all proxies are deployed, we can transfer ownership of the AddressManager to the ProxyAdmin.
        output.addressManager.transferOwnership(address(output.opChainProxyAdmin));

        // Eventually we will switch from DelayedWETHPermissionedGameProxy to DelayedWETHPermissionlessGameProxy.
        output.delayedWETHPermissionedGameProxy = IDelayedWETH(
            payable(deployProxy(l2ChainId, output.opChainProxyAdmin, saltMixer, "DelayedWETHPermissionedGame"))
        );

        // While not a proxy, we deploy the PermissionedDisputeGame here as well because it's bespoke per chain.
        output.permissionedDisputeGame = IPermissionedDisputeGame(
            Blueprint.deployFrom(
                blueprint.permissionedDisputeGame1,
                blueprint.permissionedDisputeGame2,
                computeSalt(l2ChainId, saltMixer, "PermissionedDisputeGame"),
                encodePermissionedFDGConstructor(
                    IFaultDisputeGame.GameConstructorParams({
                        gameType: _input.disputeGameType,
                        absolutePrestate: _input.disputeAbsolutePrestate,
                        maxGameDepth: _input.disputeMaxGameDepth,
                        splitDepth: _input.disputeSplitDepth,
                        clockExtension: _input.disputeClockExtension,
                        maxClockDuration: _input.disputeMaxClockDuration,
                        vm: IBigStepper(implementation.mipsImpl),
                        weth: IDelayedWETH(payable(address(output.delayedWETHPermissionedGameProxy))),
                        anchorStateRegistry: IAnchorStateRegistry(address(output.anchorStateRegistryProxy)),
                        l2ChainId: _input.l2ChainId
                    }),
                    _input.roles.proposer,
                    _input.roles.challenger
                )
            )
        );

        // -------- Set and Initialize Proxy Implementations --------
        bytes memory data;

        data = encodeL1ERC721BridgeInitializer(output);
        upgradeToAndCall(
            output.opChainProxyAdmin, address(output.l1ERC721BridgeProxy), implementation.l1ERC721BridgeImpl, data
        );

        data = encodeOptimismPortalInitializer(output);
        upgradeToAndCall(
            output.opChainProxyAdmin, address(output.optimismPortalProxy), implementation.optimismPortalImpl, data
        );

        // First we upgrade the implementation so it's version can be retrieved, then we initialize
        // it afterwards. See the comments in encodeSystemConfigInitializer to learn more.
        upgradeTo(output.opChainProxyAdmin, payable(address(output.systemConfigProxy)), implementation.systemConfigImpl);
        data = encodeSystemConfigInitializer(_input, output);
        upgradeToAndCall(
            output.opChainProxyAdmin, address(output.systemConfigProxy), implementation.systemConfigImpl, data
        );

        data = encodeOptimismMintableERC20FactoryInitializer(output);
        upgradeToAndCall(
            output.opChainProxyAdmin,
            address(output.optimismMintableERC20FactoryProxy),
            implementation.optimismMintableERC20FactoryImpl,
            data
        );

        data = encodeL1CrossDomainMessengerInitializer(output);
        upgradeToAndCall(
            output.opChainProxyAdmin,
            address(output.l1CrossDomainMessengerProxy),
            implementation.l1CrossDomainMessengerImpl,
            data
        );

        data = encodeL1StandardBridgeInitializer(output);
        upgradeToAndCall(
            output.opChainProxyAdmin, address(output.l1StandardBridgeProxy), implementation.l1StandardBridgeImpl, data
        );

        data = encodeDelayedWETHInitializer(_input);
        // Eventually we will switch from DelayedWETHPermissionedGameProxy to DelayedWETHPermissionlessGameProxy.
        upgradeToAndCall(
            output.opChainProxyAdmin,
            address(output.delayedWETHPermissionedGameProxy),
            implementation.delayedWETHImpl,
            data
        );

        // We set the initial owner to this contract, set game implementations, then transfer ownership.
        data = encodeDisputeGameFactoryInitializer();
        upgradeToAndCall(
            output.opChainProxyAdmin,
            address(output.disputeGameFactoryProxy),
            implementation.disputeGameFactoryImpl,
            data
        );
        output.disputeGameFactoryProxy.setImplementation(
            GameTypes.PERMISSIONED_CANNON, IDisputeGame(address(output.permissionedDisputeGame))
        );
        output.disputeGameFactoryProxy.transferOwnership(address(_input.roles.opChainProxyAdminOwner));

        data = encodeAnchorStateRegistryInitializer(_input, output);
        upgradeToAndCall(
            output.opChainProxyAdmin,
            address(output.anchorStateRegistryProxy),
            implementation.anchorStateRegistryImpl,
            data
        );

        // -------- Finalize Deployment --------
        // Transfer ownership of the ProxyAdmin from this contract to the specified owner.
        output.opChainProxyAdmin.transferOwnership(_input.roles.opChainProxyAdminOwner);

        emit Deployed(l2ChainId, msg.sender, abi.encode(output));
        return output;
    }

    /// @notice Upgrades a set of chains to the latest implementation contracts
    /// @param _opChains Array of OpChain structs, one per chain to upgrade
    /// @dev This function is intended to be called via DELEGATECALL from the Upgrade Controller Safe
    function upgrade(OpChain[] memory _opChains) external virtual {
        //if (address(this) == address(thisOPCM)) revert OnlyDelegatecall();

        // If this is delegatecalled by the upgrade controller, set isRC to false first, else, continue execution.
        if (address(this) == upgradeController) {
            // Set isRC to false.
            // This function asserts that the caller is the upgrade controller.
            super.setRC(false);
        }

        Implementations memory impls = super.implementations();
        Blueprints memory bps = super.blueprints();
        // TODO: upgrading the SuperchainConfig and ProtocolVersions (in a new function)

        for (uint256 i = 0; i < _opChains.length; i++) {
            // After Upgrade 13, we will be able to use systemConfigProxy.getAddresses() here.
            ISystemConfig.Addresses memory opChainAddrs = ISystemConfig.Addresses({
                l1CrossDomainMessenger: _opChains[i].systemConfigProxy.l1CrossDomainMessenger(),
                l1ERC721Bridge: _opChains[i].systemConfigProxy.l1ERC721Bridge(),
                l1StandardBridge: _opChains[i].systemConfigProxy.l1StandardBridge(),
                disputeGameFactory: _opChains[i].systemConfigProxy.disputeGameFactory(),
                optimismPortal: _opChains[i].systemConfigProxy.optimismPortal(),
                optimismMintableERC20Factory: _opChains[i].systemConfigProxy.optimismMintableERC20Factory()
            });

            if (IOptimismPortal2(payable(opChainAddrs.optimismPortal)).superchainConfig() != superchainConfig) {
                revert SuperchainConfigMismatch(_opChains[i].systemConfigProxy);
            }

            // -------- Upgrade Contracts Stored in SystemConfig --------
            upgradeTo(_opChains[i].proxyAdmin, address(_opChains[i].systemConfigProxy), impls.systemConfigImpl);
            upgradeTo(_opChains[i].proxyAdmin, opChainAddrs.l1CrossDomainMessenger, impls.l1CrossDomainMessengerImpl);
            upgradeTo(_opChains[i].proxyAdmin, opChainAddrs.l1ERC721Bridge, impls.l1ERC721BridgeImpl);
            upgradeTo(_opChains[i].proxyAdmin, opChainAddrs.l1StandardBridge, impls.l1StandardBridgeImpl);
            upgradeTo(_opChains[i].proxyAdmin, opChainAddrs.disputeGameFactory, impls.disputeGameFactoryImpl);
            upgradeTo(_opChains[i].proxyAdmin, opChainAddrs.optimismPortal, impls.optimismPortalImpl);
            upgradeTo(
                _opChains[i].proxyAdmin,
                opChainAddrs.optimismMintableERC20Factory,
                impls.optimismMintableERC20FactoryImpl
            );

            // -------- Discover and Upgrade Proofs Contracts --------
            // Note that, the code below uses several independently scoped blocks to avoid stack too deep errors.

            // All chains have the Permissioned Dispute Game. We get it first so that we can use it to
            // retrieve its WETH and the Anchor State Registry when we need them.
            IPermissionedDisputeGame permissionedDisputeGame = IPermissionedDisputeGame(
                address(
                    getGameImplementation(
                        IDisputeGameFactory(opChainAddrs.disputeGameFactory), GameTypes.PERMISSIONED_CANNON
                    )
                )
            );
            // We're also going to need the l2ChainId below, so we cache it in the outer scope.
            uint256 l2ChainId = permissionedDisputeGame.l2ChainId();

            // Replace the Anchor State Registry Proxy with a new Proxy and Implementation
            // For this upgrade, we are replacing the previous Anchor State Registry, thus we:
            // 1. deploy a new Anchor State Registry proxy
            // 2. get the starting anchor root corresponding to the currently respected game type.
            // 3. initialize the proxy with that anchor root
            IAnchorStateRegistry newAnchorStateRegistryProxy;
            {
                // Deploy a new proxy, because we're replacing the old one.
                newAnchorStateRegistryProxy = IAnchorStateRegistry(
                    deployProxy({
                        _l2ChainId: l2ChainId,
                        _proxyAdmin: _opChains[i].proxyAdmin,
                        _saltMixer: "v2.0.0",
                        _contractName: "AnchorStateRegistry"
                    })
                );

                // Get the starting anchor root by:
                // 1. getting the anchor state registry from the Permissioned Dispute Game.
                // 2. getting the respected game type from the OptimismPortal.
                // 3. getting the anchor root for the respected game type from the Anchor State Registry.
                {
                    GameType gameType = IOptimismPortal2(payable(opChainAddrs.optimismPortal)).respectedGameType();
                    (Hash root, uint256 l2BlockNumber) = permissionedDisputeGame.anchorStateRegistry().anchors(gameType);
                    OutputRoot memory startingAnchorRoot = OutputRoot({ root: root, l2BlockNumber: l2BlockNumber });

                    upgradeToAndCall(
                        _opChains[i].proxyAdmin,
                        address(newAnchorStateRegistryProxy),
                        impls.anchorStateRegistryImpl,
                        abi.encodeCall(
                            IAnchorStateRegistry.initialize,
                            (
                                superchainConfig,
                                IDisputeGameFactory(opChainAddrs.disputeGameFactory),
                                IOptimismPortal2(payable(opChainAddrs.optimismPortal)),
                                startingAnchorRoot
                            )
                        )
                    );
                }

                deployAndSetNewGameImpl({
                    _proxyAdmin: _opChains[i].proxyAdmin,
                    _currentGame: IDisputeGame(address(permissionedDisputeGame)),
                    _newAnchorStateRegistryProxy: newAnchorStateRegistryProxy,
                    _gameType: GameTypes.PERMISSIONED_CANNON,
                    _implementations: impls,
                    _blueprints: bps,
                    _opChainAddrs: opChainAddrs,
                    _l2ChainId: l2ChainId
                });
            }

            // Now retrieve the permissionless game. If it exists, upgrade its weth and replace its implementation.
            IFaultDisputeGame permissionlessDisputeGame = IFaultDisputeGame(
                address(getGameImplementation(IDisputeGameFactory(opChainAddrs.disputeGameFactory), GameTypes.CANNON))
            );
            if (address(permissionlessDisputeGame) != address(0)) {
                deployAndSetNewGameImpl({
                    _proxyAdmin: _opChains[i].proxyAdmin,
                    _currentGame: IDisputeGame(address(permissionlessDisputeGame)),
                    _newAnchorStateRegistryProxy: newAnchorStateRegistryProxy,
                    _gameType: GameTypes.CANNON,
                    _implementations: impls,
                    _blueprints: bps,
                    _opChainAddrs: opChainAddrs,
                    _l2ChainId: l2ChainId
                });
            }

            // Emit the upgraded event with the address of the caller. Since this will be a delegatecall,
            // the caller will be the value of the ADDRESS opcode.
            emit Upgraded(l2ChainId, _opChains[i].systemConfigProxy, address(this));
        }
    }
}
