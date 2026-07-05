import os

version       = "0.1"
author        = "DriftTeam"
description   = "Drift - Lightweight IDE / text editor"
license       = "AGPL-3.0 or Commercial"
srcDir        = "src"
bin           = @["drift"]

requires "nim >= 2.0.2"
requires "chronos"
requires "https://github.com/bung87/lsp_client >= 0.5.0"
requires "pixie >= 5.0.0"
requires "yaml"
requires "darwin"
requires "https://github.com/bung87/uirelays#tmp2"
requires "https://github.com/bung87/nim-tinyfiledialogs"
requires "markdown >= 0.8.0"
