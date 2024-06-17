# Balanced Package Structure

## Overview

The Balanced package within the Sui blockchain ecosystem is designed to manage various aspects of the decentralized application (dApp) including asset management, cross-chain communication, and stablecoin operations. This structure ensures efficient handling of these operations through well-defined modules and unique identifiers.

## Modules

The Balanced package is divided into three main modules, each responsible for specific functionalities:

### 1. Asset Manager: asset_manager
- **Purpose**: Manages assets within the Balanced ecosystem.
  
### 2. xCall Manager: xcall_manager
- **Purpose**: Facilitates cross-chain administration from the icon side.

### 3. Balanced Dollar: balanced_dollar_crosschain
- **Purpose**: Manages the crosschain bnUSD operations within the Balanced ecosystem.

## Identifiers

### Package ID
- **Definition**: A unique identifier for the entire Balanced package within the Sui blockchain.
- **Usage**: Used for function calls and interactions with the Balanced package from the Sui side.

### Cap IDs
- **Definition**: Unique identifiers for each module within the Balanced package, akin to contract addresses in other blockchain ecosystems.
- **Usage**:
  - Each module (Asset Manager, xCall Manager, Balanced Dollar) has its own Cap ID.
  - Cap IDs are used for configuring the Balanced package in other chains.
  - They enable specific interactions and operations within each module, ensuring modular and isolated management of functionalities.

## Usage in Cross-Chain Configuration

- **Configuration**: Cap IDs are critical for setting up Balanced in cross-chain environments. They ensure that each module can be independently addressed and interacted with from other chains.
- **Function Calls**: While the Package ID is used for function calls from the Sui blockchain, module-name allow for precise targeting of module-specific operations in the following way like

```shell
sui client call --package <package_id> --module <module_name> --function <function name> --args <argument_lists> 
```


