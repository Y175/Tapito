#!/usr/bin/env python3
"""Source grammar/config/safety assertions. NOT a Swift compiler or iOS build."""
import json, pathlib, plistlib, subprocess
import yaml
ROOT = pathlib.Path(__file__).resolve().parents[1]
files = sorted(p for folder in ('Tapito', 'TapitoTests') for p in (ROOT / folder).rglob('*.swift'))
# Parse with the selected Xcode toolchain so Swift 6 / current SDK syntax is
# accepted. Parsing alone does not replace the separate iPhoneOS type-check build.
sdk = subprocess.check_output(['xcrun', '--sdk', 'iphoneos', '--show-sdk-path'], text=True).strip()
subprocess.run(['xcrun', 'swiftc', '-frontend', '-parse', '-target', 'arm64-apple-ios27.0',
                '-sdk', sdk, *map(str, files)], check=True)
project = yaml.safe_load((ROOT / 'project.yml').read_text())
assert project['packages']['SwiftAgentKit']['path'] == 'Vendor/SwiftAgentKit'
upstream = json.loads((ROOT / 'Vendor/SwiftAgentKit/UPSTREAM.json').read_text())
assert upstream['revision'] == '84ddf324fd2a223834323537eb3f8746d669753b'
assert project['packages']['ProviderKit']['path'] == 'ProviderKit'
assert 'TapitoTests' in project['targets']
plistlib.loads((ROOT / 'Tapito/PrivacyInfo.xcprivacy').read_bytes())
provider = (ROOT / 'Tapito/Agent/Providers.swift').read_text()
controller = (ROOT / 'Tapito/Agent/AgentSessionController.swift').read_text()
engine = (ROOT / 'TapitoAgentKit/Sources/TapitoAgentSwiftAgentKit/SwiftAgentEngine.swift').read_text()
bridge = (ROOT / 'Tapito/Bridge/NCMDeviceBridge.swift').read_text()
tools = (ROOT / 'Tapito/Agent/DeviceTools.swift').read_text()
assert 'completionHandler(nil)' in provider
transport = (ROOT / 'ProviderKit/Sources/OpenAIAdapter/ResponsesTransport.swift').read_text()
assert 'URLSessionConfiguration.ephemeral' in transport
assert 'ModelError.interrupted' in provider
assert 'reasoning: parsed.reasoning' not in provider
assert 'guard !stopping else { return }' in controller
assert 'func cancelTransport()' in bridge and 'flow.releaseConnection(owner:' in bridge
assert 'assistant.cancel()' in controller and 'requestCancel()' in engine and 'provider?.cancel()' in controller
assert 'await oldTask?.value' in controller
assert 'rewriteMessages' in engine
assert 'guard await approve' in tools and 'image = nil' in tools
assert 'requiresConfirmationEvenWhenAutonomous' not in tools # app-owned gate cannot be waived
background_plist = plistlib.loads((ROOT / 'Tapito/Info.plist').read_bytes())
assert 'screen-capture' not in background_plist['UIBackgroundModes']
assert '$(PRODUCT_BUNDLE_IDENTIFIER).pairing' in background_plist['BGTaskSchedulerPermittedIdentifiers']
print(f'PASS: {len(files)} Swift files parsed; project/plist/pins and source guardrail assertions checked')
print('This script does not perform Swift type-check, dependency resolution, Xcode, XCTest, Simulator, or device/TLS tests.')
