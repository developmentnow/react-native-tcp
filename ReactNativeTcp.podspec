Pod::Spec.new do |s|
  s.name         = "ReactNativeTcp"
  s.version      = "3.3.0"
  s.summary      = "node's net API for react-native"
  s.homepage     = "https://github.com/PeelTechnologies/react-native-tcp"
  s.license      = { :type => "MIT" }
  s.authors      = { "Andy Prock" => "aprock@protonmail.com" }
  s.platform     = :ios, "8.0"
  s.source       = { :path => "." }
  s.source_files = "ios", "ios/**/*.{h,m}"
  s.dependency 'React'end