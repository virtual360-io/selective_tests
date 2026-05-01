# frozen_string_literal: true

$LOAD_PATH.push File.expand_path('lib', __dir__)
require 'selective_tests/version'

Gem::Specification.new do |spec|
  spec.name        = 'selective_tests'
  spec.version     = SelectiveTests::VERSION
  spec.authors     = ['Virtual360']
  spec.email       = ['dev@virtual360.io']
  spec.summary     = 'Selective test execution: track per-test file dependencies and pick tests for changed files.'
  spec.description = <<~DESC.strip
    Records which files each Minitest test touches via Ruby's stdlib Coverage and exposes a CLI
    that, given a list of changed files (e.g., a PR diff), returns the tests that exercise those files.
    A test file passed as input is always returned. Designed to mirror the workflow described in
    Stripe's "Selective test execution" post for a Ruby monorepo.
  DESC
  spec.homepage    = 'https://github.com/virtual360-io/v360'
  spec.license     = 'MIT'
  spec.required_ruby_version = '>= 3.0'

  spec.files       = Dir['{lib,exe}/**/*', 'README.md']
  spec.bindir      = 'exe'
  spec.executables = ['selective-tests']
  spec.require_paths = ['lib']

  spec.metadata['rubygems_mfa_required'] = 'true'
end
