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
  # Longdo Map is a WebView (Longdo Map JS API3) provider - the map is loaded inside a WKWebView
  # from https://api.longdo.com/map3/. There is no vendor binary to vendor or depend on, so unlike
  # the other providers this podspec declares only MapConductorCore.
end
