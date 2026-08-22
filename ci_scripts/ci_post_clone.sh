#!/bin/sh
# Xcode Cloud post-clone hook. Xcode Cloud runs this on the ephemeral build machine after cloning,
# with the working directory set to this script's own directory.
#
# Pensieve.xcodeproj is a BUILD PRODUCT — generated from project.yml, gitignored — so a fresh clone
# has no project for Xcode Cloud to find, which is why cloud builds fail before compiling anything.
# This generates it, mirroring the "Generate Xcode project" step in .github/workflows/ci.yml.
set -eu

cd "$CI_PRIMARY_REPOSITORY_PATH"

HOMEBREW_NO_AUTO_UPDATE=1 brew install xcodegen
xcodegen generate

# Xcode Cloud invokes xcodebuild itself, so the -skipMacroValidation and
# -skipPackagePluginValidation flags that the Makefile and GitHub Actions pass cannot be added to
# that invocation. The machine-wide `defaults write` is the only lever left — normally a bad trade,
# but this machine is destroyed after the build. Without it the SQLiteData macro plugins
# (swift-structured-queries, swift-perception) fail fingerprint validation and the build dies.
defaults write com.apple.dt.Xcode IDESkipMacroFingerprintValidation -bool YES
defaults write com.apple.dt.Xcode IDESkipPackagePluginFingerprintValidation -bool YES
