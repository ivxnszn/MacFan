DERIVED_DATA := $(CURDIR)/build/DerivedData
DESTINATION := platform=macOS,arch=arm64

.PHONY: generate build test install open

generate:
	xcodegen generate

build: generate
	xcodebuild -project MacFan.xcodeproj -scheme MacFan -configuration Debug -destination '$(DESTINATION)' -derivedDataPath '$(DERIVED_DATA)' build

test: generate
	xcodebuild -project MacFan.xcodeproj -scheme MacFan -destination '$(DESTINATION)' -derivedDataPath '$(DERIVED_DATA)' test

install:
	zsh Scripts/install-local.sh

open: build
	open '$(DERIVED_DATA)/Build/Products/Debug/MacFan.app'
