# LSP Configuration Guide

## Overview

Drift supports multiple LSP (Language Server Protocol) servers for Nim development. You can switch between servers and configure them through the configuration file.

## Configuration File

The configuration is stored in `~/.config/drift/config.json`.

### Basic Structure

```json
{
  "windowWidth": 1200,
  "windowHeight": 800,
  "windowTitle": "Drift",
  "theme": "dark",
  "lspServer": "minlsp",
  "lspConfig": {}
}
```

## Supported LSP Servers

### 1. minlsp (Default)
- **Executable**: `minlsp`
- **Description**: Minimal LSP server for Nim
- **Configuration**: Usually requires no special configuration

```json
{
  "lspServer": "minlsp",
  "lspConfig": {}
}
```

### 2. nimlangserver
- **Executable**: `nimlangserver`
- **Description**: Full-featured Nim language server
- **Configuration**: Supports various options

```json
{
  "lspServer": "languageserver",
  "lspConfig": {
    "nim": {
      "projectMapping": {},
      "timeout": 120000
    }
  }
}
```

### 3. nimlsp
- **Executable**: `nimlsp`
- **Description**: Alternative Nim LSP implementation
- **Configuration**: Supports project-specific settings

```json
{
  "lspServer": "nimlsp",
  "lspConfig": {
    "nim": {
      "projectMapping": {},
      "checkOnSave": true
    }
  }
}
```

## Switching LSP Servers

### Via UI
1. Click on the LSP status in the status bar (bottom right)
2. Select the desired server from the menu
3. The server will restart automatically with the new configuration

### Via Configuration File
1. Edit `~/.config/drift/config.json`
2. Change the `lspServer` field to your desired server
3. Optionally update `lspConfig` with server-specific options
4. Restart Drift or switch to a different server via UI to reload

## Server-Specific Configuration

### Common Options

Most Nim LSP servers support these initialization options:

```json
{
  "lspConfig": {
    "nim": {
      "projectMapping": {
        "/path/to/project": "/path/to/nimble/file.nimble"
      },
      "checkOnSave": true,
      "nimsuggestPath": "/path/to/nimsuggest",
      "timeout": 120000
    }
  }
}
```

### Configuration Fields

- **projectMapping**: Maps project directories to their nimble files
- **checkOnSave**: Enable/disable syntax checking on file save
- **nimsuggestPath**: Custom path to nimsuggest executable
- **timeout**: Request timeout in milliseconds

## Troubleshooting

### Server Not Found
If you see "LSP server not found" error:
1. Ensure the server executable is installed
2. Verify it's in your system PATH
3. Try running the executable from terminal to confirm

### Server Not Responding
If the server starts but doesn't respond:
1. Check the configuration in `lspConfig`
2. Try with empty configuration first: `"lspConfig": {}`
3. Check stderr output for error messages

### Configuration Not Applied
If configuration changes aren't taking effect:
1. Ensure the config file is valid JSON
2. Switch to a different server and back to reload
3. Restart Drift completely

## Example Configurations

### Minimal Configuration
```json
{
  "lspServer": "minlsp",
  "lspConfig": {}
}
```

### Advanced Configuration
```json
{
  "lspServer": "languageserver",
  "lspConfig": {
    "nim": {
      "projectMapping": {
        "/home/user/myproject": "/home/user/myproject/myproject.nimble"
      },
      "checkOnSave": true,
      "timeout": 120000,
      "nimsuggestPath": "/usr/local/bin/nimsuggest"
    }
  }
}
```

## Notes

- Configuration is loaded when the LSP server starts
- Switching servers automatically reloads configuration
- Open documents are automatically synchronized with the new server
- Diagnostics are cleared when switching servers
