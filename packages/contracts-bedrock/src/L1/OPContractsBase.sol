// SPDX-License-Identifier: MIT
pragma solidity 0.8.15;

// Libraries
import { Blueprint } from "src/libraries/Blueprint.sol";
import { Constants } from "src/libraries/Constants.sol";
import { Bytes } from "src/libraries/Bytes.sol";
import { Claim, Hash, Duration, GameType, GameTypes, OutputRoot } from "src/dispute/lib/Types.sol";

// Interfaces
import { ISemver } from "interfaces/universal/ISemver.sol";
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

abstract contract OPContractsBase is ISemver {
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

    /// @notice The address of the upgrade controller.
    address public immutable upgradeController;

    /// @notice Whether this is a release candidate.
    bool public isRC = true;

    /// @notice Returns the release string. Appends "-rc" if this is a release candidate.
    function l1ContractsRelease() external view returns (string memory) {
        return isRC ? string.concat(L1_CONTRACTS_RELEASE, "-rc") : L1_CONTRACTS_RELEASE;
    }

    // -------- Errors --------

    /// @notice Thrown when an address other than the upgrade controller calls the setRC function.
    error OnlyUpgradeController();

    /// @notice Thrown when an address is the zero address.
    error AddressNotFound(address who);

    /// @notice Throw when a contract address has no code.
    error AddressHasNoCode(address who);

    /// @notice Thrown when a release version is already set.
    error AlreadyReleased();

    /// @notice Thrown when an invalid `l2ChainId` is provided to `deploy`.
    error InvalidChainId();

    /// @notice Thrown when a role's address is not valid.
    error InvalidRoleAddress(string role);

    /// @notice Thrown when the latest release is not set upon initialization.
    error LatestReleaseNotSet();

    /// @notice Thrown when the starting anchor root is not provided.
    error InvalidStartingAnchorRoot();

    /// @notice Thrown when certain methods are called outside of a DELEGATECALL.
    error OnlyDelegatecall();

    /// @notice Thrown when game configs passed to addGameType are invalid.
    error InvalidGameConfigs();

    /// @notice Thrown when the SuperchainConfig of the chain does not match the SuperchainConfig of this OPCM.
    error SuperchainConfigMismatch(ISystemConfig systemConfig);

    /// @notice Thrown when the input arrays are of different lengths.
    error InvalidInputLength();

    /// @notice Verifies that all inputs are valid and reverts if any are invalid.
    /// Typically the proxy admin owner is expected to have code, but this is not enforced here.
    function assertValidInputs(DeployInput calldata _input) internal view {
        if (_input.l2ChainId == 0 || _input.l2ChainId == block.chainid) revert InvalidChainId();

        if (_input.roles.opChainProxyAdminOwner == address(0)) revert InvalidRoleAddress("opChainProxyAdminOwner");
        if (_input.roles.systemConfigOwner == address(0)) revert InvalidRoleAddress("systemConfigOwner");
        if (_input.roles.batcher == address(0)) revert InvalidRoleAddress("batcher");
        if (_input.roles.unsafeBlockSigner == address(0)) revert InvalidRoleAddress("unsafeBlockSigner");
        if (_input.roles.proposer == address(0)) revert InvalidRoleAddress("proposer");
        if (_input.roles.challenger == address(0)) revert InvalidRoleAddress("challenger");

        if (_input.startingAnchorRoot.length == 0) revert InvalidStartingAnchorRoot();
    }

    /// @notice Maps an L2 chain ID to an L1 batch inbox address as defined by the standard
    /// configuration's convention. This convention is `versionByte || keccak256(bytes32(chainId))[:19]`,
    /// where || denotes concatenation`, versionByte is 0x00, and chainId is a uint256.
    /// https://specs.optimism.io/protocol/configurability.html#consensus-parameters
    function chainIdToBatchInboxAddress(uint256 _l2ChainId) public pure returns (address) {
        bytes1 versionByte = 0x00;
        bytes32 hashedChainId = keccak256(bytes.concat(bytes32(_l2ChainId)));
        bytes19 first19Bytes = bytes19(hashedChainId);
        return address(uint160(bytes20(bytes.concat(versionByte, first19Bytes))));
    }

    /// @notice Helper method for computing a salt that's used in CREATE2 deployments.
    /// Including the contract name ensures that the resultant address from CREATE2 is unique
    /// across our smart contract system. For example, we deploy multiple proxy contracts
    /// with the same bytecode from this contract, so they each require a unique salt for determinism.
    function computeSalt(
        uint256 _l2ChainId,
        string memory _saltMixer,
        string memory _contractName
    )
        internal
        pure
        returns (bytes32)
    {
        return keccak256(abi.encode(_l2ChainId, _saltMixer, _contractName));
    }

    // -------- Initializer Encoding --------

    /// @notice Helper method for encoding the L1ERC721Bridge initializer data.
    function encodeL1ERC721BridgeInitializer(DeployOutput memory _output)
        internal
        view
        virtual
        returns (bytes memory)
    {
        return abi.encodeCall(IL1ERC721Bridge.initialize, (_output.l1CrossDomainMessengerProxy, superchainConfig));
    }

    /// @notice Helper method for encoding the OptimismPortal initializer data.
    function encodeOptimismPortalInitializer(DeployOutput memory _output)
        internal
        view
        virtual
        returns (bytes memory)
    {
        return abi.encodeCall(
            IOptimismPortal2.initialize,
            (
                _output.disputeGameFactoryProxy,
                _output.systemConfigProxy,
                superchainConfig,
                GameTypes.PERMISSIONED_CANNON
            )
        );
    }

    /// @notice Helper method for encoding the SystemConfig initializer data.
    function encodeSystemConfigInitializer(
        DeployInput memory _input,
        DeployOutput memory _output
    )
        internal
        view
        virtual
        returns (bytes memory)
    {
        (IResourceMetering.ResourceConfig memory referenceResourceConfig, ISystemConfig.Addresses memory opChainAddrs) =
            defaultSystemConfigParams(_input, _output);

        return abi.encodeCall(
            ISystemConfig.initialize,
            (
                _input.roles.systemConfigOwner,
                _input.basefeeScalar,
                _input.blobBasefeeScalar,
                bytes32(uint256(uint160(_input.roles.batcher))), // batcherHash
                _input.gasLimit,
                _input.roles.unsafeBlockSigner,
                referenceResourceConfig,
                chainIdToBatchInboxAddress(_input.l2ChainId),
                opChainAddrs
            )
        );
    }

    /// @notice Helper method for encoding the OptimismMintableERC20Factory initializer data.
    function encodeOptimismMintableERC20FactoryInitializer(DeployOutput memory _output)
        internal
        pure
        virtual
        returns (bytes memory)
    {
        return abi.encodeCall(IOptimismMintableERC20Factory.initialize, (address(_output.l1StandardBridgeProxy)));
    }

    /// @notice Helper method for encoding the L1CrossDomainMessenger initializer data.
    function encodeL1CrossDomainMessengerInitializer(DeployOutput memory _output)
        internal
        view
        virtual
        returns (bytes memory)
    {
        return abi.encodeCall(IL1CrossDomainMessenger.initialize, (superchainConfig, _output.optimismPortalProxy));
    }

    /// @notice Helper method for encoding the L1StandardBridge initializer data.
    function encodeL1StandardBridgeInitializer(DeployOutput memory _output)
        internal
        view
        virtual
        returns (bytes memory)
    {
        return abi.encodeCall(IL1StandardBridge.initialize, (_output.l1CrossDomainMessengerProxy, superchainConfig));
    }

    function encodeDisputeGameFactoryInitializer() internal view virtual returns (bytes memory) {
        // This contract must be the initial owner so we can set game implementations, then
        // ownership is transferred after.
        return abi.encodeCall(IDisputeGameFactory.initialize, (address(this)));
    }

    function encodeAnchorStateRegistryInitializer(
        DeployInput memory _input,
        DeployOutput memory _output
    )
        internal
        view
        virtual
        returns (bytes memory)
    {
        OutputRoot memory startingAnchorRoot = abi.decode(_input.startingAnchorRoot, (OutputRoot));
        return abi.encodeCall(
            IAnchorStateRegistry.initialize,
            (superchainConfig, _output.disputeGameFactoryProxy, _output.optimismPortalProxy, startingAnchorRoot)
        );
    }

    function encodeDelayedWETHInitializer(DeployInput memory _input) internal view virtual returns (bytes memory) {
        return abi.encodeCall(IDelayedWETH.initialize, (_input.roles.opChainProxyAdminOwner, superchainConfig));
    }

    function encodePermissionlessFDGConstructor(IFaultDisputeGame.GameConstructorParams memory _params)
        internal
        view
        virtual
        returns (bytes memory)
    {
        bytes memory dataWithSelector = abi.encodeCall(IFaultDisputeGame.__constructor__, (_params));
        return Bytes.slice(dataWithSelector, 4);
    }

    function encodePermissionedFDGConstructor(
        IFaultDisputeGame.GameConstructorParams memory _params,
        address _proposer,
        address _challenger
    )
        internal
        view
        virtual
        returns (bytes memory)
    {
        bytes memory dataWithSelector =
            abi.encodeCall(IPermissionedDisputeGame.__constructor__, (_params, _proposer, _challenger));
        return Bytes.slice(dataWithSelector, 4);
    }

    /// @notice Returns default, standard config arguments for the SystemConfig initializer.
    /// This is used by subclasses to reduce code duplication.
    function defaultSystemConfigParams(
        DeployInput memory, /* _input */
        DeployOutput memory _output
    )
        internal
        view
        virtual
        returns (IResourceMetering.ResourceConfig memory resourceConfig_, ISystemConfig.Addresses memory opChainAddrs_)
    {
        // We use assembly to easily convert from IResourceMetering.ResourceConfig to ResourceMetering.ResourceConfig.
        // This is required because we have not yet fully migrated the codebase to be interface-based.
        IResourceMetering.ResourceConfig memory resourceConfig = Constants.DEFAULT_RESOURCE_CONFIG();
        assembly ("memory-safe") {
            resourceConfig_ := resourceConfig
        }

        opChainAddrs_ = ISystemConfig.Addresses({
            l1CrossDomainMessenger: address(_output.l1CrossDomainMessengerProxy),
            l1ERC721Bridge: address(_output.l1ERC721BridgeProxy),
            l1StandardBridge: address(_output.l1StandardBridgeProxy),
            disputeGameFactory: address(_output.disputeGameFactoryProxy),
            optimismPortal: address(_output.optimismPortalProxy),
            optimismMintableERC20Factory: address(_output.optimismMintableERC20FactoryProxy)
        });

        assertValidContractAddress(opChainAddrs_.l1CrossDomainMessenger);
        assertValidContractAddress(opChainAddrs_.l1ERC721Bridge);
        assertValidContractAddress(opChainAddrs_.l1StandardBridge);
        assertValidContractAddress(opChainAddrs_.disputeGameFactory);
        assertValidContractAddress(opChainAddrs_.optimismPortal);
        assertValidContractAddress(opChainAddrs_.optimismMintableERC20Factory);
    }

    /// @notice Makes an external call to the target to initialize the proxy with the specified data.
    /// First performs safety checks to ensure the target, implementation, and proxy admin are valid.
    function upgradeToAndCall(
        IProxyAdmin _proxyAdmin,
        address _target,
        address _implementation,
        bytes memory _data
    )
        internal
    {
        assertValidContractAddress(_implementation);

        _proxyAdmin.upgradeAndCall(payable(address(_target)), _implementation, _data);
    }

    /// @notice Updates the implementation of a proxy without calling the initializer.
    /// First performs safety checks to ensure the target, implementation, and proxy admin are valid.
    function upgradeTo(IProxyAdmin _proxyAdmin, address _target, address _implementation) internal {
        assertValidContractAddress(_implementation);

        _proxyAdmin.upgrade(payable(address(_target)), _implementation);
    }

    function assertValidContractAddress(address _who) internal view {
        if (_who.code.length == 0) revert AddressHasNoCode(_who);
    }

    /// @notice Returns the blueprint contract addresses.
    function blueprints() public view returns (Blueprints memory) {
        return blueprint;
    }

    /// @notice Returns the implementation contract addresses.
    function implementations() public view returns (Implementations memory) {
        return implementation;
    }

    /// @notice Returns the implementation contract address for a given game type.
    function getGameImplementation(
        IDisputeGameFactory _disputeGameFactory,
        GameType _gameType
    )
        internal
        view
        returns (IDisputeGame)
    {
        return _disputeGameFactory.gameImpls(_gameType);
    }

    /// @notice Sets the RC flag.
    function setRC(bool _isRC) external {
        if (msg.sender != upgradeController) revert OnlyUpgradeController();
        isRC = _isRC;
    }

    function getGameConstructorParams(IFaultDisputeGame _disputeGame)
        internal
        view
        returns (IFaultDisputeGame.GameConstructorParams memory)
    {
        IFaultDisputeGame.GameConstructorParams memory params = IFaultDisputeGame.GameConstructorParams({
            gameType: _disputeGame.gameType(),
            absolutePrestate: _disputeGame.absolutePrestate(),
            maxGameDepth: _disputeGame.maxGameDepth(),
            splitDepth: _disputeGame.splitDepth(),
            clockExtension: _disputeGame.clockExtension(),
            maxClockDuration: _disputeGame.maxClockDuration(),
            vm: _disputeGame.vm(),
            weth: _disputeGame.weth(),
            anchorStateRegistry: _disputeGame.anchorStateRegistry(),
            l2ChainId: _disputeGame.l2ChainId()
        });
        return params;
    }

    /// @notice For a given game type, does the following:
    /// 1. Get and upgrade the DelayedWETH Proxy
    /// 2. Deploy a new game
    /// 3. Set the new game as the implementation on the OptimismPortal
    function deployAndSetNewGameImpl(
        IProxyAdmin _proxyAdmin,
        IDisputeGame _currentGame,
        IAnchorStateRegistry _newAnchorStateRegistryProxy,
        GameType _gameType,
        Blueprints memory _blueprints,
        Implementations memory _implementations,
        ISystemConfig.Addresses memory _opChainAddrs,
        uint256 _l2ChainId
    )
        internal
    {
        // Get and upgrade the WETH proxy
        IDelayedWETH delayedWethProxy = IFaultDisputeGame(address(_currentGame)).weth();
        upgradeTo(_proxyAdmin, address(delayedWethProxy), _implementations.delayedWETHImpl);

        // Get the constructor params for the game
        IFaultDisputeGame.GameConstructorParams memory params =
            getGameConstructorParams(IFaultDisputeGame(address(_currentGame)));
        params.anchorStateRegistry = IAnchorStateRegistry(address(_newAnchorStateRegistryProxy));

        IDisputeGame newGame;
        if (GameType.unwrap(_gameType) == GameType.unwrap(GameTypes.PERMISSIONED_CANNON)) {
            address proposer = IPermissionedDisputeGame(address(_currentGame)).proposer();
            address challenger = IPermissionedDisputeGame(address(_currentGame)).challenger();
            newGame = IDisputeGame(
                Blueprint.deployFrom(
                    _blueprints.permissionedDisputeGame1,
                    _blueprints.permissionedDisputeGame2,
                    computeSalt(_l2ChainId, "v2.0.0", "PermissionedDisputeGame"),
                    encodePermissionedFDGConstructor(params, proposer, challenger)
                )
            );
        } else {
            newGame = IDisputeGame(
                Blueprint.deployFrom(
                    _blueprints.permissionlessDisputeGame1,
                    _blueprints.permissionlessDisputeGame2,
                    computeSalt(_l2ChainId, "v2.0.0", "PermissionlessDisputeGame"),
                    encodePermissionlessFDGConstructor(params)
                )
            );
        }
        IDisputeGameFactory(_opChainAddrs.disputeGameFactory).setImplementation(_gameType, IDisputeGame(newGame));
    }
}
