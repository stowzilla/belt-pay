# frozen_string_literal: true

require 'belt/pay/cli'

run_pay_secret_command = lambda do |command, environment|
  args = ["secrets:#{command}"]
  args << environment unless environment.nil? || environment.to_s.strip.empty?

  status = Belt::Pay::CLI.start(args)
  exit status unless status.zero?
end

namespace :pay do
  desc 'Prompt without echo for Stripe secrets (BELT_ENV or pay:setup[env])'
  task :setup, [:environment] do |_task, args|
    run_pay_secret_command.call(:setup, args[:environment])
  end

  desc 'Print the decrypted Stripe secret (BELT_ENV or pay:show[env])'
  task :show, [:environment] do |_task, args|
    run_pay_secret_command.call(:show, args[:environment])
  end

  desc 'Edit the Stripe secret as JSON (BELT_ENV or pay:edit[env])'
  task :edit, [:environment] do |_task, args|
    run_pay_secret_command.call(:edit, args[:environment])
  end
end
