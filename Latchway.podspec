Pod::Spec.new do |spec|
  spec.name = 'Latchway'
  spec.version = '0.1.0'
  spec.summary = 'Device-bound access to a self-hosted Latchway gateway.'
  spec.description = <<-DESC
    Latchway authorizes iOS and React Native requests without embedding
    upstream provider credentials. It provides Secure Enclave P-256 DPoP,
    rotating Keychain sessions, URLSession integration, and optional App
    Attest support.
  DESC
  spec.homepage = 'https://github.com/Latchway/latchway-ios-sdk'
  spec.license = { type: 'Apache-2.0', file: 'LICENSE' }
  spec.authors = { 'Latchway' => 'https://github.com/Latchway' }
  spec.source = {
    git: 'https://github.com/Latchway/latchway-ios-sdk.git',
    tag: "v#{spec.version}",
  }

  spec.ios.deployment_target = '15.0'
  spec.swift_version = '6.0'
  spec.requires_arc = true
  spec.default_subspec = 'Core'
  spec.pod_target_xcconfig = {
    'SWIFT_STRICT_CONCURRENCY' => 'complete',
    'SWIFT_ACTIVE_COMPILATION_CONDITIONS' => '$(inherited) COCOAPODS',
  }

  spec.subspec 'Core' do |core|
    core.source_files = 'Sources/Latchway/**/*.swift'
    core.frameworks = 'CryptoKit', 'Foundation', 'Security'
  end

  spec.subspec 'AppAttest' do |app_attest|
    app_attest.dependency 'Latchway/Core', spec.version.to_s
    app_attest.source_files = 'Sources/LatchwayAppAttest/**/*.swift'
    app_attest.frameworks = 'DeviceCheck', 'Foundation', 'Security'
  end

  spec.subspec 'FirebaseAuth' do |firebase_auth|
    firebase_auth.dependency 'Latchway/Core', spec.version.to_s
    firebase_auth.source_files = 'Sources/LatchwayFirebaseAuth/**/*.swift'
    firebase_auth.frameworks = 'Foundation'
  end
end
