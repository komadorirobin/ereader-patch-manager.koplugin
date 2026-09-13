#!/bin/sh
set -eu

luac -p _meta.lua main.lua patchmanager_updater.lua patchsync_core.lua patchsync_service.lua
lua tests/test_patchsync.lua
lua tests/test_main.lua
lua tests/test_updater.lua
