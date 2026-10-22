#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
mkdir -p build/chatgpt-module-cache
swiftc -module-cache-path build/chatgpt-module-cache \
  OCR-Translate/Services/ChatGPTProtocol.swift \
  OCR-Translate/Services/ChatGPTIdentity.swift \
  Tests/ChatGPTProtocolTests.swift \
  -o build/chatgpt-contract-tests
build/chatgpt-contract-tests
