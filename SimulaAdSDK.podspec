Pod::Spec.new do |s|
  s.name             = "SimulaAdSDK"
  s.version          = "1.1.6-dev.1"
  s.summary          = "Interactive, AI-native ad experiences for modern apps"

  s.description      = <<-DESC
  SimulaAdSDK enables developers to integrate interactive, opt-in AI-native ads
  including sponsored characters and mini-games. Designed for high engagement,
  contextual relevance, and seamless in-app experiences.
  DESC

  s.homepage         = "https://github.com/Simula-AI-SDK/simula-ad-sdk-swift"
  # :text (not :file): the :http source zip contains only the XCFramework (SPM binaryTarget
  # requires the artifact at the zip root), so there is no LICENSE file for lint to find.
  s.license          = { :type => "MIT", :text => "MIT License — Copyright (c) 2026 Simula AI SDK. See https://github.com/Simula-AI-SDK/simula-ad-sdk-swift/blob/main/LICENSE" }
  s.author           = { "Simula AI" => "admin@simula.ad" }

  # Binary distribution (1.1.4+): a prebuilt, module-stable XCFramework. Host Xcodes never
  # compile SDK source — the mitigation for the Swift 6.1–6.3 optimizer task-teardown
  # miscompilation that aborted host apps (see the repo's swift-concurrency-task-shape skill).
  # The artifact is built + validated by .github/workflows/release.yml; resources (including
  # PrivacyInfo.xcprivacy) ship inside the framework's SimulaAdSDK_SimulaAdSDK.bundle.
  #
  # IMPORTANT: `pod trunk push` resolves this spec to static JSON on the publishing machine.
  # The layout gate below therefore RAISES when the XCFramework isn't beside the podspec and
  # SIMULA_LOCAL_DEV isn't set — a push from a bare checkout fails loudly instead of silently
  # publishing a SOURCE pod (which would re-expose the miscompile to hosts). Push from the
  # release staging layout (podspec + extracted SimulaAdSDK.xcframework side by side).
  s.source           = {
    :http => "https://github.com/Simula-AI-SDK/simula-ad-sdk-swift/releases/download/#{s.version}/SimulaAdSDK.xcframework.zip"
  }

  s.platform         = :ios, "15.0"
  s.swift_version    = "5.9"

  # Layout gate (fail-loud). Consumers must always get the prebuilt binary; compiling Sources/
  # with a host toolchain re-exposes the miscompile. So:
  #   - Release staging layout (XCFramework beside the podspec — the release zip): binary.
  #   - Local source development (:path install for unreleased testing): must OPT IN explicitly
  #     with SIMULA_LOCAL_DEV=1. Never publish from this mode.
  #   - Anything else (e.g. a trunk/spec push from a bare checkout): raise, so a release-time
  #     misconfiguration fails loudly instead of silently shipping a SOURCE pod.
  if File.directory?(File.join(__dir__, "SimulaAdSDK.xcframework"))
    s.vendored_frameworks = "SimulaAdSDK.xcframework"
  elsif ENV["SIMULA_LOCAL_DEV"] == "1"
    s.source_files = "Sources/SimulaAdSDK/**/*.swift"
    s.resource_bundles = {
      "SimulaAdSDK" => ["Sources/SimulaAdSDK/Resources/*"]
    }
  else
    raise <<-MSG
[SimulaAdSDK] SimulaAdSDK.xcframework not found next to the podspec.
Consumers must receive the prebuilt binary (mitigation for the Swift 6.1-6.3
host-toolchain task-teardown miscompile). To fix:
  - Releasing: push from the staging layout — podspec + extracted
    SimulaAdSDK.xcframework side by side (see .github/workflows/release.yml).
  - Local source development: set SIMULA_LOCAL_DEV=1 for a :path install of Sources/.
    MSG
  end

  s.frameworks       = [
    "StoreKit",
    "SafariServices",
    "WebKit",
    "SwiftUI",
    "Combine"
  ]

  s.requires_arc     = true
  s.module_name      = "SimulaAdSDK"

  # Optional but recommended
  s.documentation_url = "https://github.com/Simula-AI-SDK/simula-ad-sdk-swift"
end
