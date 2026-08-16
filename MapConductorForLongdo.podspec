Pod::Spec.new do |s|
  s.name = "MapConductorForLongdo"
  s.version = "1.2.0"
  s.summary = "MapConductor's Longdo Map provider."
  s.license = { :type => "Apache-2.0", :file => "LICENSE" }
  s.author = "MapConductor"
  s.homepage = "https://github.com/MapConductor/ios-for-longdo"
  s.source = { :path => __dir__ }
  s.platform = :ios, "16.0"
  s.swift_version = "5.9"
  s.source_files = "Sources/MapConductorForLongdo/**/*.swift"
  s.dependency "MapConductorCore"
  # Longdo Map renders inside a WKWebView (Longdo Map JS API3), but the map object itself
  # (`LongdoMap`, the gesture/bridge plumbing) comes from the vendor's own binary framework,
  # so `import LongdoMapFramework` needs it here too - not only in Package.swift.
  #
  # LongdoMapFramework.xcframework is dynamic (`Mach-O 64-bit dynamically linked shared library`),
  # and the vendor publishes the pod on CocoaPods trunk, so per ios-sdk/CLAUDE.md's
  # "iOS Provider Distribution" section this stays a plain `s.dependency` - nothing gets embedded
  # or redistributed by this repo. The version matches the SPM pin in Package.resolved (4.1.4).
  s.dependency "LongdoMapFramework", "~> 4.1"
end
