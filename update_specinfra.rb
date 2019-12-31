#!/usr/bin/env ruby
require 'erb'
require 'fileutils'
require 'shellwords'
require 'tmpdir'

SPECINFRA_REPO    = 'mizzy/specinfra'
SPECINFRA_VERSION = 'v2.82.5'

module GitHubFetcher
  def self.fetch(repo, tag:, path:)
    Dir.mktmpdir do |dir|
      Dir.chdir(dir) do
        url = "https://github.com/#{repo}/archive/#{tag}.tar.gz"
        system("curl -L --fail --retry 3 --retry-delay 1 #{url} -o - | tar zxf -")
        FileUtils.mv("#{File.basename(repo)}-#{tag.sub(/\Av/, '')}", path)
      end
    end
  end
end

# Generate mrblib from lib
class MRubySpecinfraBuilder
  # Upper rules match first.
  RENAME_RULES = {
    %r[\A/specinfra/backend/base\.rb\z]       => '/specinfra/backend/00_base.rb',
    %r[\A/specinfra/backend/exec\.rb\z]       => '/specinfra/backend/01_exec.rb',
    %r[\A/specinfra/backend/powershell/]      => '/specinfra/backend/02_powershell/',
    %r[\A/specinfra/command.rb\z]             => '/specinfra/00_command.rb',
    %r[\A/specinfra/command/module\.rb\z]     => '/specinfra/command/00_module.rb',
    %r[\A/specinfra/command/module/]          => '/specinfra/command/00_module/',
    %r[\A/specinfra/command/base\.rb\z]       => '/specinfra/command/01_base.rb',
    %r[\A/specinfra/command/base/]            => '/specinfra/command/01_base/',
    %r[\A/specinfra/command/linux\.rb\z]      => '/specinfra/command/02_linux.rb',
    %r[\A/specinfra/command/linux/base\.rb\z] => '/specinfra/command/02_linux/00_base.rb',
    %r[\A/specinfra/command/linux/]           => '/specinfra/command/02_linux/',
    %r[\A/specinfra/command/solaris\.rb\z]    => '/specinfra/command/02_solaris.rb',
    %r[\A/specinfra/command/solaris/]         => '/specinfra/command/02_solaris/',
    %r[\A/specinfra/command/debian\.rb\z]     => '/specinfra/command/03_debian.rb',
    %r[\A/specinfra/command/debian/]          => '/specinfra/command/03_debian/',
    %r[\A/specinfra/command/redhat\.rb\z]     => '/specinfra/command/03_redhat.rb',
    %r[\A/specinfra/command/redhat/]          => '/specinfra/command/03_redhat/',
    %r[\A/specinfra/command/suse\.rb\z]       => '/specinfra/command/03_suse.rb',
    %r[\A/specinfra/command/suse/]            => '/specinfra/command/03_suse/',
    %r[\A/specinfra/command/fedora\.rb\z]     => '/specinfra/command/04_fedora.rb',
    %r[\A/specinfra/command/fedora/]          => '/specinfra/command/04_fedora/',
    %r[\A/specinfra/command/ubuntu\.rb\z]     => '/specinfra/command/04_ubuntu.rb',
    %r[\A/specinfra/command/ubuntu/]          => '/specinfra/command/04_ubuntu/',
    %r[\A/specinfra/core\.rb\z]               => '/00_specinfra/core.rb',
    %r[\A/specinfra/ext/string\.rb\z]         => '/specinfra/string_utils.rb',
  }

  def initialize(lib:, mrblib:)
    @lib = lib
    @mrblib = mrblib
  end

  def build
    Dir.glob(File.join(@lib, '**/*.rb')).sort.each do |src_fullpath|
      src_path = src_fullpath.sub(/\A#{Regexp.escape(@lib)}/, '')
      dest_path = src_path.dup
      if rule = RENAME_RULES.find { |from, _to| dest_path.match?(from) }
        dest_path.sub!(rule.first, rule.last)
      end
      dest_fullpath = File.join(@mrblib, dest_path)

      FileUtils.mkdir_p(File.dirname(dest_fullpath))
      FileUtils.cp(src_fullpath, dest_fullpath)

      src = File.read(dest_fullpath)
      patch_source!(src, path: src_path)
      File.write(dest_fullpath, src)
    end
  end

  private

  def patch_source!(src, path:)
    # Not using mruby-require for single binary build. Require order is resolved by RENAME_RULES.
    src.gsub!(/^ *require ["'][^"']+["']( .+)?$/, '# \0')

    # No `defined?` in mruby.
    src.gsub!(/ defined\?\(([^)]+)\)/, ' Object.const_defined?("\1")')

    # `LoadError` doesn't exist in mruby. Because we suppress `require`, everything could happen.
    src.gsub!(/^( *)rescue LoadError/, "\\1  raise 'mruby-specinfra does not support dynamic require'\n\\1rescue StandardError")

    case path
    when '/specinfra.rb'
      # 'include' is not defined. Besides we don't need the top-level include feature.
      src.gsub!(/^include .+$/, '# \0')
    when '/specinfra/backend/exec.rb'
      # Specinfra::Backend::Exec#spawn_command uses Thread. mruby-thread had issues and we're just using mruby-open3 instead.
      src.gsub!(
        /^( +)def spawn_command\(cmd\)$/,
        "\\1def spawn_command(cmd)\n" +
        "\\1  out, err, result = Open3.capture3(@config[:shell], '-c', cmd)\n" + # workaround. Just `Open3.capture3(cmd)` hangs for some reason
        "\\1  return out, err, result.exitstatus\n" +
        "\\1end\n" +
        "\n" +
        "\\1def __unused_original_spawn_method(cmd)"
      )
    when '/specinfra/ext/class.rb'
      # Special code generation for missing ObjectSpace
      src.replace(generate_class_ext)
    end
  end

  def generate_class_ext
    classes = `find #{@lib.shellescape} -type f -exec grep "\\.subclasses" {} \\;`.each_line.map do |line|
      line.sub(/\A */, '').sub(/\.subclasses.*\n\z/, '')
    end

    subclasses = {}
    classes.each do |klass|
      subclasses[klass] = `find #{@lib.shellescape} -type f -exec grep "#{klass}" {} \\;`
        .scan(/#{klass}::[^:\n ]+/).sort.uniq
    end

    ERB.new(<<~'RUBY', trim_mode: '%').result(binding)
      class Class
        def subclasses
          case self.to_s
      % classes.each do |klass|
          when "<%= klass %>"
            [
      %   subclasses.fetch(klass).each do |subclass|
              <%= subclass %>,
      %   end
            ]
      % end
          else
            raise "#{self} is not supposed by mruby-specinfra Class#subclasses"
          end
        end
      end
    RUBY
  end
end

FileUtils.rm_rf(specinfra_dir = File.expand_path('./specinfra', __dir__))
GitHubFetcher.fetch(SPECINFRA_REPO, tag: SPECINFRA_VERSION, path: specinfra_dir)

FileUtils.rm_rf(mrblib_dir = File.expand_path('./mrblib', __dir__))
MRubySpecinfraBuilder.new(
  lib: File.join(specinfra_dir, 'lib'),
  mrblib: mrblib_dir,
).build
