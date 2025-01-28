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
    // -------- Structs --------

    /// @notice Represents the roles that can be set when deploying a standard OP Stack chain.
    struct Roles {
        address opChainProxyAdminOwner;
        address systemConfigOwner;
        address batcher;
        address unsafeBlockSigner;
        address proposer;
        address challenger;
    }

    /// @notice The full set of inputs to deploy a new OP Stack chain.
    struct DeployInput {
        Roles roles;
        uint32 basefeeScalar;
        uint32 blobBasefeeScalar;
        uint256 l2ChainId;
        // The correct type is OutputRoot memory but OP Deployer does not yet support structs.
        bytes startingAnchorRoot;
        // The salt mixer is used as part of making the resulting salt unique.
        string saltMixer;
        uint64 gasLimit;
        // Configurable dispute game parameters.
        GameType disputeGameType;
        Claim disputeAbsolutePrestate;
        uint256 disputeMaxGameDepth;
        uint256 disputeSplitDepth;
        Duration disputeClockExtension;
        Duration disputeMaxClockDuration;
    }

    /// @notice The full set of outputs from deploying a new OP Stack chain.
    struct DeployOutput {
        IProxyAdmin opChainProxyAdmin;
        IAddressManager addressManager;
        IL1ERC721Bridge l1ERC721BridgeProxy;
        ISystemConfig systemConfigProxy;
        IOptimismMintableERC20Factory optimismMintableERC20FactoryProxy;
        IL1StandardBridge l1StandardBridgeProxy;
        IL1CrossDomainMessenger l1CrossDomainMessengerProxy;
        // Fault proof contracts below.
        IOptimismPortal2 optimismPortalProxy;
        IDisputeGameFactory disputeGameFactoryProxy;
        IAnchorStateRegistry anchorStateRegistryProxy;
        IFaultDisputeGame faultDisputeGame;
        IPermissionedDisputeGame permissionedDisputeGame;
        IDelayedWETH delayedWETHPermissionedGameProxy;
        IDelayedWETH delayedWETHPermissionlessGameProxy;
    }

    /// @notice Addresses of ERC-5202 Blueprint contracts. There are used for deploying full size
    /// contracts, to reduce the code size of this factory contract. If it deployed full contracts
    /// using the `new Proxy()` syntax, the code size would get large fast, since this contract would
    /// contain the bytecode of every contract it deploys. Therefore we instead use Blueprints to
    /// reduce the code size of this contract.
    struct Blueprints {
        address addressManager;
        address proxy;
        address proxyAdmin;
        address l1ChugSplashProxy;
        address resolvedDelegateProxy;
        address permissionedDisputeGame1;
        address permissionedDisputeGame2;
        address permissionlessDisputeGame1;
        address permissionlessDisputeGame2;
    }

    /// @notice The latest implementation contracts for the OP Stack.
    struct Implementations {
        address l1ERC721BridgeImpl;
        address optimismPortalImpl;
        address systemConfigImpl;
        address optimismMintableERC20FactoryImpl;
        address l1CrossDomainMessengerImpl;
        address l1StandardBridgeImpl;
        address disputeGameFactoryImpl;
        address anchorStateRegistryImpl;
        address delayedWETHImpl;
        address mipsImpl;
    }

    /// @notice The input required to identify a chain for upgrading.
    struct OpChain {
        ISystemConfig systemConfigProxy;
        IProxyAdmin proxyAdmin;
    }

    struct AddGameInput {
        string saltMixer;
        ISystemConfig systemConfig;
        IProxyAdmin proxyAdmin;
        IDelayedWETH delayedWETH;
        GameType disputeGameType;
        Claim disputeAbsolutePrestate;
        uint256 disputeMaxGameDepth;
        uint256 disputeSplitDepth;
        Duration disputeClockExtension;
        Duration disputeMaxClockDuration;
        uint256 initialBond;
        IBigStepper vm;
        bool permissioned;
    }

    struct AddGameOutput {
        IDelayedWETH delayedWETH;
        IFaultDisputeGame faultDisputeGame;
    }

    // -------- Constants and Variables --------

    /// @custom:semver 1.0.0-beta.35
    function version() public pure virtual returns (string memory) {
        return "1.0.0-beta.35";
    }

    /// @notice Address of the SuperchainConfig contract shared by all chains.
    ISuperchainConfig public immutable superchainConfig;

    /// @notice Address of the ProtocolVersions contract shared by all chains.
    IProtocolVersions public immutable protocolVersions;

    /// @notice L1 smart contracts release deployed by this version of OPCM. This is used in opcm to signal which
    /// version of the L1 smart contracts is deployed. It takes the format of `op-contracts/vX.Y.Z`.
    string internal L1_CONTRACTS_RELEASE;

    /// @notice Addresses of the Blueprint contracts.
    /// This is internal because if public the autogenerated getter method would return a tuple of
    /// addresses, but we want it to return a struct.
    Blueprints internal blueprint;

    /// @notice Addresses of the latest implementation contracts.
    Implementations internal implementation;

    /// @notice The OPContractsManager contract that is currently being used. This is needed in the upgrade function
    /// which is intended to be DELEGATECALLed.
    //OPContractsManager internal immutable thisOPCM;

    /// @notice The address of the upgrade controller.
    address public immutable upgradeController;

    /// @notice Whether this is a release candidate.
    bool public isRC = true;

    /// @notice Returns the release string. Appends "-rc" if this is a release candidate.
    function l1ContractsRelease() external view virtual returns (string memory) {
        return isRC ? string.concat(L1_CONTRACTS_RELEASE, "-rc") : L1_CONTRACTS_RELEASE;
    }

    constructor(
        ISuperchainConfig _superchainConfig,
        IProtocolVersions _protocolVersions,
        string memory _l1ContractsRelease,
        Blueprints memory _blueprints,
        Implementations memory _implementations,
        address _upgradeController
    ) {
        // assertValidContractAddress(address(_superchainConfig));
        // assertValidContractAddress(address(_protocolVersions));
        superchainConfig = _superchainConfig;
        protocolVersions = _protocolVersions;
        L1_CONTRACTS_RELEASE = _l1ContractsRelease;

        blueprint = _blueprints;
        implementation = _implementations;
        thisOPCM = this;
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
        if (address(this) == address(thisOPCM)) revert OnlyDelegatecall();

        // If this is delegatecalled by the upgrade controller, set isRC to false first, else, continue execution.
        if (address(this) == upgradeController) {
            // Set isRC to false.
            // This function asserts that the caller is the upgrade controller.
            thisOPCM.setRC(false);
        }

        Implementations memory impls = thisOPCM.implementations();
        Blueprints memory bps = thisOPCM.blueprints();
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

    /// @notice Deterministically deploys a new proxy contract owned by the provided ProxyAdmin.
    /// The salt is computed as a function of the L2 chain ID, the salt mixer and the contract name.
    /// This is required because we deploy many identical proxies, so they each require a unique salt for determinism.
    function deployProxy(
        uint256 _l2ChainId,
        IProxyAdmin _proxyAdmin,
        string memory _saltMixer,
        string memory _contractName
    )
        internal
        returns (address)
    {
        bytes32 salt = computeSalt(_l2ChainId, _saltMixer, _contractName);
        return Blueprint.deployFrom(thisOPCM.blueprints().proxy, salt, abi.encode(_proxyAdmin));
    }

    /// @notice addGameType deploys a new dispute game and links it to the DisputeGameFactory. The inputted _gameConfigs
    /// must be added in ascending GameType order.
    function addGameType(AddGameInput[] memory _gameConfigs) public virtual returns (AddGameOutput[] memory) {
        if (address(this) == address(thisOPCM)) revert OnlyDelegatecall();
        if (_gameConfigs.length == 0) revert InvalidGameConfigs();

        AddGameOutput[] memory outputs = new AddGameOutput[](_gameConfigs.length);
        Blueprints memory bps = thisOPCM.blueprints();

        // Store last game config as an int256 so that we can ensure that the same game config is not added twice.
        // Using int256 generates cheaper, simpler bytecode.
        int256 lastGameConfig = -1;

        for (uint256 i = 0; i < _gameConfigs.length; i++) {
            AddGameInput memory gameConfig = _gameConfigs[i];

            // This conversion is safe because the GameType is a uint32, which will always fit in an int256.
            int256 gameTypeInt = int256(uint256(gameConfig.disputeGameType.raw()));
            // Ensure that the game configs are added in ascending order, and not duplicated.
            if (lastGameConfig >= gameTypeInt) revert InvalidGameConfigs();
            lastGameConfig = gameTypeInt;

            // Grab the FDG from the SystemConfig.
            IFaultDisputeGame fdg = IFaultDisputeGame(
                address(
                    getGameImplementation(
                        IDisputeGameFactory(gameConfig.systemConfig.disputeGameFactory()), GameTypes.PERMISSIONED_CANNON
                    )
                )
            );
            // Pull out the chain ID.
            uint256 l2ChainId = fdg.l2ChainId();

            // Deploy a new DelayedWETH proxy for this game if one hasn't already been specified. Leaving
            /// gameConfig.delayedWETH as the zero address will cause a new DelayedWETH to be deployed for this game.
            if (address(gameConfig.delayedWETH) == address(0)) {
                outputs[i].delayedWETH = IDelayedWETH(
                    payable(deployProxy(l2ChainId, gameConfig.proxyAdmin, gameConfig.saltMixer, "DelayedWETH"))
                );

                // Initialize the proxy.
                upgradeToAndCall(
                    gameConfig.proxyAdmin,
                    address(outputs[i].delayedWETH),
                    thisOPCM.implementations().delayedWETHImpl,
                    abi.encodeCall(IDelayedWETH.initialize, (gameConfig.proxyAdmin.owner(), superchainConfig))
                );
            } else {
                outputs[i].delayedWETH = gameConfig.delayedWETH;
            }

            // The below sections are functionally the same. Both deploy a new dispute game. The dispute game type is
            // either permissioned or permissionless depending on game config.
            if (gameConfig.permissioned) {
                IPermissionedDisputeGame pdg = IPermissionedDisputeGame(address(fdg));
                outputs[i].faultDisputeGame = IFaultDisputeGame(
                    Blueprint.deployFrom(
                        bps.permissionedDisputeGame1,
                        bps.permissionedDisputeGame2,
                        computeSalt(l2ChainId, gameConfig.saltMixer, "PermissionedDisputeGame"),
                        encodePermissionedFDGConstructor(
                            IFaultDisputeGame.GameConstructorParams(
                                gameConfig.disputeGameType,
                                gameConfig.disputeAbsolutePrestate,
                                gameConfig.disputeMaxGameDepth,
                                gameConfig.disputeSplitDepth,
                                gameConfig.disputeClockExtension,
                                gameConfig.disputeMaxClockDuration,
                                gameConfig.vm,
                                outputs[i].delayedWETH,
                                pdg.anchorStateRegistry(),
                                l2ChainId
                            ),
                            pdg.proposer(),
                            pdg.challenger()
                        )
                    )
                );
            } else {
                outputs[i].faultDisputeGame = IFaultDisputeGame(
                    Blueprint.deployFrom(
                        bps.permissionlessDisputeGame1,
                        bps.permissionlessDisputeGame2,
                        computeSalt(l2ChainId, gameConfig.saltMixer, "PermissionlessDisputeGame"),
                        encodePermissionlessFDGConstructor(
                            IFaultDisputeGame.GameConstructorParams(
                                gameConfig.disputeGameType,
                                gameConfig.disputeAbsolutePrestate,
                                gameConfig.disputeMaxGameDepth,
                                gameConfig.disputeSplitDepth,
                                gameConfig.disputeClockExtension,
                                gameConfig.disputeMaxClockDuration,
                                gameConfig.vm,
                                outputs[i].delayedWETH,
                                fdg.anchorStateRegistry(),
                                l2ChainId
                            )
                        )
                    )
                );
            }

            // As a last step, register the new game type with the DisputeGameFactory. If the game type already exists,
            // then its implementation will be overwritten.
            IDisputeGameFactory dgf = IDisputeGameFactory(gameConfig.systemConfig.disputeGameFactory());
            dgf.setImplementation(gameConfig.disputeGameType, IDisputeGame(address(outputs[i].faultDisputeGame)));
            dgf.setInitBond(gameConfig.disputeGameType, gameConfig.initialBond);
        }

        return outputs;
    }
}
