# frozen_string_literal: true

require 'rails_helper'
require 'open3'
require 'tmpdir'

# This contract exercises an executable, not a Ruby class.
RSpec.describe 'SOUQ touchpoints checker' do # rubocop:disable RSpec/DescribeClass
  let(:directory) { Dir.mktmpdir('souq-touchpoints-') }

  around do |example|
    setup_repository
    example.run
  ensure
    FileUtils.remove_entry(directory)
  end

  def git(*args)
    output, error, status = Open3.capture3(
      { 'GIT_AUTHOR_NAME' => 'SOUQ Test', 'GIT_AUTHOR_EMAIL' => 'test@example.invalid',
        'GIT_COMMITTER_NAME' => 'SOUQ Test', 'GIT_COMMITTER_EMAIL' => 'test@example.invalid' },
      'git', *args, chdir: directory
    )
    raise error unless status.success?

    output.strip
  end

  def write(path, content)
    absolute = File.join(directory, path)
    FileUtils.mkdir_p(File.dirname(absolute))
    File.write(absolute, content)
  end

  def setup_repository
    git('init', '-q')
    write('Gemfile', "# base\n")
    write('app/models/status.rb', "# base\n")
    write("app/nom avec \u00e9.rb", "# base\n")
    git('add', '.')
    git('commit', '-qm', 'Base')
    git('tag', 'v4.7.4')
    script = Rails.root.join('engines', 'souq', 'bin', 'souq-check-touchpoints').read
    # Only the isolated fixture copy accepts the synthetic repository's SHA.
    script = script.sub('d04059fc80be5cbba6b4dd5a8b94d63ffff09f2c', git('rev-parse', 'HEAD'))
    write('engines/souq/bin/souq-check-touchpoints', script)
    write('engines/souq/UPSTREAM_TOUCHPOINTS.md', Rails.root.join('engines', 'souq', 'UPSTREAM_TOUCHPOINTS.md').read)
  end

  def check
    Open3.capture3(RbConfig.ruby, 'engines/souq/bin/souq-check-touchpoints', chdir: directory)
  end

  def expect_forbidden(path)
    output, _error, status = check
    expect(status.exitstatus).to eq(1)
    expect(output).to include(path.dump)
  end

  it '1 accepts an allowed change before and after commit' do
    write('Gemfile', "# changed\n")
    expect(check.last.exitstatus).to eq(0)
    git('add', 'Gemfile')
    git('commit', '-qm', 'Allowed')
    expect(check.last.exitstatus).to eq(0)
  end

  it '2 accepts new engine files' do
    write('engines/souq/new.rb', "# new\n")
    expect(check.last.exitstatus).to eq(0)
  end

  it '3 rejects an unstaged forbidden change' do
    write('app/models/status.rb', "# changed\n")
    expect_forbidden('app/models/status.rb')
  end

  it '4 rejects staged and committed forbidden changes' do
    write('app/models/status.rb', "# changed\n")
    git('add', 'app/models/status.rb')
    expect_forbidden('app/models/status.rb')
    git('commit', '-qm', 'Forbidden')
    expect_forbidden('app/models/status.rb')
  end

  it '5 rejects an untracked forbidden file' do
    write('app/new.rb', "# new\n")
    expect_forbidden('app/new.rb')
  end

  it '6a rejects deletion before and after commit' do
    File.unlink(File.join(directory, 'app/models/status.rb'))
    expect_forbidden('app/models/status.rb')
    git('add', '-u')
    git('commit', '-qm', 'Delete')
    expect_forbidden('app/models/status.rb')
  end

  it '6b rejects both paths of a rename before and after commit' do
    git('mv', 'app/models/status.rb', 'app/renamed.rb')
    expect_forbidden('app/models/status.rb')
    expect_forbidden('app/renamed.rb')
    git('commit', '-qm', 'Rename')
    expect_forbidden('app/models/status.rb')
    expect_forbidden('app/renamed.rb')
  end

  it '7 preserves spaces and accented characters in paths' do
    path = "app/nom avec \u00e9.rb"
    write(path, "# changed\n")
    expect_forbidden(path)
  end

  it 'rejects a base with an unexpected SHA with exit 2' do
    write('Gemfile', "# next\n")
    git('add', 'Gemfile')
    git('commit', '-qm', 'Next')
    git('tag', '-f', 'v4.7.4')
    _output, error, status = check
    expect(status.exitstatus).to eq(2)
    expect(error).to include('base inattendue')
  end
end
