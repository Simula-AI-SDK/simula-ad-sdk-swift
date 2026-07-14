Pod::Spec.new do |s|
  s.name             = "SimulaAdSDK"
  s.version          = "1.1.4-beta.2"
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
  # Local `:path` installs (no XCFramework present) fall back to compiling Sources/ so
  # unreleased changes can be tested from sibling demo apps without a binary build.
  s.source           = {
    :http => "https://github.com/Simula-AI-SDK/simula-ad-sdk-swift/releases/download/#{s.version}/SimulaAdSDK.xcframework.zip"
  }

  s.platform         = :ios, "15.0"
  s.swift_version    = "5.9"

  xcframework_at_root = File.join(__dir__, "SimulaAdSDK.xcframework")
  # Only the release-zip layout (XCFramework at the podspec root) uses the binary.
  # Do NOT auto-pick build/SimulaAdSDK.xcframework — a stale local archive would
  # silently shadow Sources/ during :path installs used for unreleased testing.
  if File.directory?(xcframework_at_root)
    s.vendored_frameworks = "SimulaAdSDK.xcframework"
  else
    s.source_files = "Sources/SimulaAdSDK/**/*.swift"
    s.resource_bundles = {
      "SimulaAdSDK" => [
        "Sources/SimulaAdSDK/Resources/*.png",
        "Sources/SimulaAdSDK/Resources/PrivacyInfo.xcprivacy"
      ]
    }
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
