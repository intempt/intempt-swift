Pod::Spec.new do |s|
  s.name             = 'Intempt'
  s.version          = '0.1.1'
  s.summary          = 'Analytics, personalization and consent for Apple platforms.'

  s.description      = <<-DESC
    The Intempt SDK for iOS, iPadOS, tvOS, macOS and watchOS. Event tracking,
    user and account identification, consent capture and enforcement, product
    and commerce events, experiments and recommendation feeds, and APNs push
    registration for journeys.
  DESC

  s.homepage         = 'https://github.com/intempt/intempt-swift'
  s.license          = { :type => 'Apache-2.0', :file => 'LICENSE' }
  s.author           = { 'Intempt Technologies' => 'support@intempt.com' }
  s.documentation_url = 'https://intempt.com/docs/api/sdk/ios'

  s.source           = {
    :git => 'https://github.com/intempt/intempt-swift.git',
    :tag => "v#{s.version}"
  }

  # Must match Package.swift. A pod that advertises a lower floor than the
  # package builds for one consumer and fails for the other.
  s.ios.deployment_target     = '15.0'
  s.tvos.deployment_target    = '15.0'
  s.osx.deployment_target     = '12.0'
  s.watchos.deployment_target = '8.0'

  s.swift_versions = ['5.9']

  # Resources/ carries the privacy manifest and is excluded here so it is not
  # compiled as source; it is declared as a resource bundle below.
  s.source_files = 'Sources/Intempt/**/*.swift'

  # Apple requires the privacy manifest inside the framework. resource_bundles,
  # not resources: a loose file at the app level is not what the App Store
  # checks for a third-party SDK.
  s.resource_bundles = {
    'Intempt' => ['Sources/Intempt/Resources/PrivacyInfo.xcprivacy']
  }

  # The event queue is SQLite with WAL. Package.swift links this too.
  s.libraries = 'sqlite3'
end
