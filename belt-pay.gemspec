# frozen_string_literal: true

require_relative 'lib/belt/pay/version'

Gem::Specification.new do |spec|
  spec.name          = 'belt-pay'
  spec.version       = Belt::Pay::VERSION
  spec.authors       = ['Stowzilla']
  spec.email         = ['andy@stowzilla.com', 'adam@stowzilla.com']

  spec.summary       = 'Payments and subscriptions for Belt applications via Stripe'
  spec.description   = 'Belt plugin providing payment collection, subscriptions, and billing management. ' \
                        'Ships with Stripe as the default provider. Includes webhook handling, ' \
                        'customer provisioning, and a Transaction model for audit logging.'
  spec.homepage      = 'https://github.com/stowzilla/belt-pay'
  spec.license       = 'MIT'
  spec.required_ruby_version = '>= 3.3'

  spec.metadata['homepage_uri'] = spec.homepage
  spec.metadata['source_code_uri'] = spec.homepage
  spec.metadata['changelog_uri'] = "#{spec.homepage}/blob/main/CHANGELOG.md"
  spec.metadata['rubygems_mfa_required'] = 'true'

  spec.files = Dir['lib/**/*', 'lambda/**/*', 'LICENSE', 'README.md', 'CHANGELOG.md']
  spec.require_paths = ['lib']

  spec.add_dependency 'belt', '~> 0.2'
  spec.add_dependency 'stripe', '~> 13.0'
end
