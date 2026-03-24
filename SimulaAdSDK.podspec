Pod::Spec.new do |s|
  s.name             = "SimulaAdSDK"
  s.version          = "1.0.2"
  s.summary          = "Interactive, AI-native ad experiences for modern apps"

  s.description      = <<-DESC
  SimulaAdSDK enables developers to integrate interactive, opt-in AI-native ads
  including sponsored characters and mini-games. Designed for high engagement,
  contextual relevance, and seamless in-app experiences.
  DESC

  s.homepage         = "https://github.com/Simula-AI-SDK/simula-ad-sdk-swift"
  s.license          = { :type => "MIT", :file => "LICENSE" }
  s.author           = { "Simula AI" => "admin@simula.ad" }

  s.source           = {
    :git => "https://github.com/Simula-AI-SDK/simula-ad-sdk-swift.git",
    :tag => s.version.to_s
  }

  s.platform         = :ios, "15.0"
  s.swift_version    = "5.9"

  s.source_files     = "Sources/SimulaAdSDK/**/*.swift"

  s.resource_bundles = {
    "SimulaAdSDK" => [
      "Sources/SimulaAdSDK/Resources/*.png",
      "Sources/SimulaAdSDK/Resources/PrivacyInfo.xcprivacy"
    ]
  }

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