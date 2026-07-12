#!/bin/sh

# Xcode Cloud runs this script after cloning the repo, before resolving
# packages and building.
#
# mlx-swift-lm ships Swift macros (e.g. MLXHuggingFaceMacros) and build-tool
# plugins. In a clean CI environment these are untrusted, so `xcodebuild
# archive` fails with "Macro ... must be enabled before it can be used"
# (exit code 65) — the non-interactive equivalent of the "Trust & Enable"
# prompt you get once in local Xcode. These defaults tell the Xcode Cloud
# builder to skip the interactive fingerprint validation so the macros and
# plugins are trusted automatically.

defaults write com.apple.dt.Xcode IDESkipMacroFingerprintValidation -bool YES
defaults write com.apple.dt.Xcode IDESkipPackagePluginFingerprintValidatation -bool YES

echo "ci_post_clone: macro + package-plugin fingerprint validation disabled for CI"
