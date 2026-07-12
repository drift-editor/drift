import os

version       = "0.1"
author        = "DriftTeam"
description   = "Drift - Lightweight IDE / text editor"
license       = "AGPL-3.0 or Commercial"
srcDir        = "src"
bin           = @["drift"]

requires "nim >= 2.0.2"
requires "chronos >= 4.2"
requires "https://github.com/bung87/lsp_client >= 0.5.0"
requires "pixie >= 5.0.0"
requires "yaml"
requires "darwin"
requires "https://github.com/bung87/uirelays#71b89a0ce1f51da63a7880577c3e46eba1ce9537"
requires "tinyfiledialogs"
requires "markdown >= 0.8.0"
requires "jsony >= 1.0.0"
