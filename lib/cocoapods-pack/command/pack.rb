# frozen_string_literal: true

#
#  Copyright 2021 Square, Inc.
#
#  Licensed under the Apache License, Version 2.0 (the "License");
#  you may not use this file except in compliance with the License.
#  You may obtain a copy of the License at
#
#    http://www.apache.org/licenses/LICENSE-2.0
#
#  Unless required by applicable law or agreed to in writing, software
#  distributed under the License is distributed on an "AS IS" BASIS,
#  WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
#  See the License for the specific language governing permissions and
#  limitations under the License.
#

require 'cocoapods-pack/xcode_builder'
require 'cocoapods-pack/spec_generator.rb'
require 'cocoapods-pack/find_follow'
require 'cocoapods-pack/zip_file_generator'
require 'English'
require 'set'

module Pod
  class Command
    class Pack < Command
      include Pod::Config::Mixin
      include FindFollow

      LICENSE_GLOB_PATTERNS = Pod::Sandbox::FileAccessor::GLOB_PATTERNS[:license]
      CONCRETE_TARGET_NAME = 'Bin'

      XCArchive = Struct.new(:path, :podspec) do
        def dsym_paths
          Dir.glob(File.join(path, 'dSYMs', '*.dSYM'))
        end

        def bcsymbolmap_paths
          Dir.glob(File.join(path, 'BCSymbolMaps', '*.bcsymbolmap'))
        end

        def modules_path
          "#{framework_path}/Modules"
        end

        def framework_path
          "#{path}/Products/Library/Frameworks/#{podspec.module_name}.framework"
        end
      end

      self.summary = 'An xcframework and podspec generator.'
      self.description = <<-DESC
        Converts the provided `SOURCE` into a binary version with each platform packed as an `xcframework`.
        The process includes installing a CocoaPods sandbox, building it for device and simulator using the 'Release'
        configuration, zipping the output and generating a new podspec that uses the `ARTIFACT_REPO_URL` provided as the
        source. The generated podspec is also validated.
      DESC

      self.arguments = [
        CLAide::Argument.new('SOURCE', true),
        CLAide::Argument.new('ARTIFACT_REPO_URL', true)
      ]

      def self.options
        [
          ['--use-static-frameworks', 'Produce a framework that wraps a static library from the source files. ' \
            'By default dynamic frameworks are used.'],
          ['--generate-module-map', 'If specified, instead of using the default generated umbrella module map one ' \
            'will be generated based on the frameworks header dirs.'],
          ['--allow-warnings', 'Lint validates even if warnings are present.'],
          ['--repo-update', 'Force running `pod repo update` before install.'],
          ['--out-dir', 'Optional directory to use to output results into. Defaults to current working directory.'],
          ['--skip-validation', 'Skips linting the generated binary podspec.'],
          ['--skip-platforms', 'Comma-delimited platforms to skip when creating a binary.'],
          ['--xcodebuild-opts', 'Options to be passed through to xcodebuild.'],
          ['--use-json', 'Use JSON for the generated binary podspec.'],
          ['--sources=https://github.com/artsy/Specs,master', 'The sources from which to pull dependant pods ' \
            '(defaults to all available repos). Multiple sources must be comma-delimited.']
        ].concat(super)
      end

      def initialize(argv)
        @podspec_path = argv.shift_argument
        @artifact_repo_url = argv.shift_argument
        @allow_warnings = argv.flag?('allow-warnings', false)
        @repo_update = argv.flag?('repo-update', false)
        @generate_module_map = argv.flag?('generate-module-map', false)
        @use_static_frameworks = argv.flag?('use-static-frameworks', false)
        @skip_validation = argv.flag?('skip-validation', false)
        @xcodebuild_opts = argv.option('xcodebuild-opts')
        @out_dir = argv.option('out-dir', Dir.getwd)
        @skipped_platforms = argv.option('skip-platforms', '').split(',')
        @source_urls = argv.option('sources', Config.instance.sources_manager.all.map(&:url).join(',')).split(',')
        @use_json = argv.flag?('use-json', false)
        @build_settings_memoized = {}
        # {平台名 => 沙盒实例}
        @sandbox_map = {}
        @project_files_dir = nil
        @project_zips_dir = nil
        super
      end

      def validate!
        super
        help! 'A podspec file is required.' unless @podspec_path
        help! 'Must supply an output directory.' unless @out_dir
      end

      def run
        podspec = Specification.from_file(podspec_to_pack)
        @podspec = podspec
        # 输出的工程文件根目录
        @project_files_dir = File.expand_path(File.join(@out_dir, 'files', podspec.name, podspec.version.to_s))
        # 输出的压缩包根目录
        @project_zips_dir = File.expand_path(File.join(@out_dir, 'zips', podspec.name, podspec.version.to_s))
        @artifact_repo_url ||= podspec.attributes_hash['artifact_repo_url']
        FileUtils.mkdir_p(@project_files_dir)
        FileUtils.mkdir_p(@project_zips_dir)
        help! 'Must supply an artifact repo url.' unless @artifact_repo_url
        # stage_dir用来保存中间文件（构建的分平台的临时xcframework还有其他资源文件）
        stage_dir = File.join(@project_files_dir, 'staged')
        FileUtils.rm_rf(stage_dir)
        FileUtils.mkdir_p(stage_dir)
        source_urls = @source_urls.map { |url| Config.instance.sources_manager.source_with_name_or_url(url) }.map(&:url)
        # 分平台构建xcframework
        available_platforms(podspec).each do |platform|
          linkage = @use_static_frameworks ? :static : :dynamic
          podfile = podfile_from_spec(platform, podspec, source_urls, linkage, @is_local)
          sandbox = install(podfile, platform, podspec)
          @sandbox_map[platform.name] = sandbox
          xcodebuild_out_dir = File.join(sandbox.root.to_s, 'xcodebuild')
          build(podspec, platform, sandbox, xcodebuild_out_dir)
          xcarchives = Dir.glob(File.join(xcodebuild_out_dir, '**', '*.xcarchive')).map do |path|
            XCArchive.new(path, podspec)
          end
          stage_platform_xcframework(platform, sandbox, podspec, xcarchives, xcodebuild_out_dir, stage_dir)
        end
        stage_additional_artifacts(podspec, stage_dir)
        zip_output_path = pack(stage_dir, @project_zips_dir, podspec.name)
        binary_podspec = generate_binary_podspec(podspec, stage_dir, zip_output_path)
        validate_binary_podspec(binary_podspec)
        UI.message "Binary pod for #{podspec.name} created successfully!".green
      rescue XcodeBuilder::BuildError => e
        raise Informative, e
      end

      private

      def install(podfile, platform, podspec)
        UI.puts "\nInstalling #{podspec.name} for #{platform.name}...\n\n".yellow
        original_config = config.clone
        # Pods安装位置
        config.installation_root = Pathname.new(File.join(@project_files_dir, 'sandbox', platform.name.to_s))
        # 创建沙盒
        sandbox = Sandbox.new(config.sandbox_root)
        # 通过沙盒和podfile创建Installer
        installer = Installer.new(sandbox, podfile)
        installer.repo_update = @repo_update
        installer.use_default_plugins = false
        # noinspection RubyResolve
        installer.podfile.installation_options.integrate_targets = false
        # noinspection RubyResolve
        installer.podfile.installation_options.deterministic_uuids = false
        # noinspection RubyResolve
        installer.podfile.installation_options.warn_for_multiple_pod_sources = false
        installer.install!

        # 恢复conifg单例
        Config.instance = original_config
        sandbox
      end

      def build(podspec, platform, sandbox, xcodebuild_out_dir)
        xcode_builder(sandbox, xcodebuild_out_dir).build(platform.name, podspec.name)
      end

      def stage_platform_xcframework(platform, sandbox, podspec, xcarchives, xcodebuild_out_dir, stage_dir)
        target = podspec.name
        staged_platform_path = File.join(stage_dir, platform.name.to_s)
        UI.puts "Staging #{platform.name}-#{target} into #{staged_platform_path}...".yellow
        FileUtils.mkdir_p(staged_platform_path)

        if @generate_module_map
          type = type_from_platform(platform)
          settings = build_settings(sandbox, xcodebuild_out_dir, platform, target, type)
          module_name = settings['PRODUCT_MODULE_NAME']
          file_accessor = Pod::Sandbox::FileAccessor.new(sandbox.pod_dir(podspec.name), podspec.consumer(platform))
          module_map_contents = module_map_contents_for_framework_header_dir(module_name, file_accessor)

          # Replace the generate module map by Xcode with the one we generated.
          xcarchives.each do |xcarchive|
            module_map = File.join(xcarchive.modules_path, 'module.modulemap')
            File.write(module_map, module_map_contents)
          end
        end

        xcframework_staged_output_path = File.join(staged_platform_path, "#{podspec.module_name}.xcframework")
        args = %w[xcodebuild -create-xcframework]
        xcarchives.each do |xcarchive|
          args << "-framework #{xcarchive.framework_path}"
          xcarchive.dsym_paths.each { |dsym_path| args << "-debug-symbols #{dsym_path}" }
          xcarchive.bcsymbolmap_paths.each { |bcsymbolmap_path| args << "-debug-symbols #{bcsymbolmap_path}" }
        end
        args << "-output #{xcframework_staged_output_path}"
        create_xcframework_cmd = args.join(' ')
        output, process_status = shellout(create_xcframework_cmd)
        return output if process_status.success?

        warn output
        raise Informative, "Failed to invoke create-xcframework command! Exit status: #{process_status.exitstatus}"
      end

      def stage_additional_artifacts(podspec, stage_dir)
        copy_vendored_frameworks(podspec, stage_dir)
        copy_vendored_libraries(podspec, stage_dir)
        copy_resource_bundles(podspec, stage_dir)
        copy_resources(podspec, stage_dir)
        copy_license(podspec, stage_dir)
      end

      def generate_binary_podspec(source_podspec, stage_dir, zip_output_path)
        name = source_podspec.name
        spec_generator = SpecGenerator.new(source_podspec, @artifact_repo_url, zip_output_path)
        available_platforms(source_podspec).each do |platform|
          type = type_from_platform(platform)
          sandbox = @sandbox_map[platform.name]
          xcodebuild_out_dir = File.join(sandbox.root.to_s, 'xcodebuild')
          settings = build_settings(sandbox, xcodebuild_out_dir, platform, name, type)
          spec_generator.add_platform(platform, "#{settings['PRODUCT_NAME']}.xcframework")
        end
        spec = spec_generator.generate
        if @use_json
          binary_spec_path = File.join(stage_dir, name + '.podspec.json')
          File.open(binary_spec_path, 'w') { |file| file.write(spec.to_pretty_json) }
        else
          binary_spec_path = File.join(stage_dir, name + '.podspec')
          File.open(binary_spec_path, 'w') { |file| file.write(spec_generator.generate_ruby_string) }
        end
        spec.instance_variable_set(:@defined_in_file, Pathname.new(binary_spec_path))
        spec
      end

      def validate_binary_podspec(podspec)
        if @skip_validation
          UI.puts 'Skipping validation phase...'.yellow
          return
        end

        UI.puts "\nValidating generated binary podspec...\n\n".yellow
        validator = Pod::Validator.new(podspec, @source_urls)
        validator.quick = false
        validator.local = true
        validator.no_clean = false
        validator.fail_fast = true
        validator.allow_warnings = @allow_warnings
        validator.no_subspecs = true
        validator.only_subspec = false
        validator.use_frameworks = true
        validator.use_static_frameworks = @use_static_frameworks
        validator.validate
        raise Informative, "The binary spec did not pass validation, due to #{validator.failure_reason}." if validator.failure_reason
      end

      def pack(input_dir, output_dir, name)
        output_path = File.join(output_dir, "#{name}.zip")
        UI.puts "\nPacking #{input_dir} into #{output_path}...\n".green
        ZipFileGenerator.new(input_dir, output_path).write { |file| File.extname(file) == '.podspec' || File.symlink?(file) }
        output_path
      end

      def module_map_contents_for_framework_header_dir(framework_name, file_accessor)
        if header_mappings_dir = file_accessor.spec_consumer.header_mappings_dir
          header_mappings_dir = file_accessor.root + header_mappings_dir
        end

        headers = {}
        file_accessor.public_headers.each do |path|
          header = if header_mappings_dir
                     path.relative_path_from(header_mappings_dir)
                   else
                     path.basename
                   end
          header = header.to_s
                         .sub(%r{\A\.?/?}, '') # remove preceding '.' or './'
          next if header.empty?

          parts = header.split('/')
          file_name = parts.pop unless path.directory?

          current_module = headers # start at the root
          while part = parts.shift
            # drill down to find / create the intermediary "submodules"
            current_module = (current_module[part] ||= {})
          end
          current_module[file_name] = file_name if file_name
        end

        modules_str = ''
        handle = lambda { |m, prefix = '', i = 2|
          m.each do |k, v|
            k = v.split('.', 2).first if v.is_a? String
            modules_str << (' ' * i) << 'module ' << k.tr('-', '_') << ' {' << "\n"
            if v.is_a? String
              header = prefix.empty? ? v : "#{prefix}/#{v}"
              modules_str << (' ' * (i + 2)) << %(header "#{header}") << "\n"
              modules_str << (' ' * (i + 2)) << 'export *' << "\n"
            else
              nested_prefix = prefix.empty? ? k : "#{prefix}/#{k}"
              handle[v, nested_prefix, i + 2]
            end
            modules_str << (' ' * i) << '}' << "\n"
          end
        }
        handle[headers]

        "framework module #{framework_name} {\n#{modules_str.chomp}\n}\n"
      end

      def build_settings(sandbox, xcodebuild_out_dir, platform, target, type = nil)
        args = [sandbox, xcodebuild_out_dir, platform, target, type]
        value = @build_settings_memoized[args]
        if value.nil?
          value = xcode_builder(sandbox, xcodebuild_out_dir).build_settings(platform, target, type)
          @build_settings_memoized[args] = value
        end
        value
      end

      def xcode_builder(sandbox, xcodebuild_out_dir)
        XcodeBuilder.new(sandbox.project_path, @xcodebuild_opts, xcodebuild_out_dir, UI, config.verbose)
      end

      def copy_vendored_frameworks(podspec, stage_dir)
        copy_vendored_artifacts(podspec, 'vendored_frameworks', stage_dir)
      end

      def copy_vendored_libraries(podspec, stage_dir)
        copy_vendored_artifacts(podspec, 'vendored_libraries', stage_dir)
      end

      def copy_vendored_artifacts(podspec, attribute, stage_dir)
        platforms = Pod::Specification::DSL::PLATFORMS
        hash = podspec.attributes_hash
        # 所有需要拷贝的vendored资源
        globs = [Array(hash[attribute])] + platforms.map { |p| Array((hash[p.to_s] || {})[attribute]) }
        globs.flatten.to_set.each { |glob| stage_glob(glob, stage_dir) }
      end

      def copy_resource_bundles(podspec, stage_dir)
        resource_bundles = podspec.attributes_hash['resource_bundles']
        return if resource_bundles.nil?

        resource_paths = []
        resource_bundles.values.map { |globspec| Array(globspec) }.flatten.each do |glob|
          podspec_dir_relative_glob(glob, include_dirs: true).each do |file_path|
            if File.file?(file_path)
              resource_paths << file_path
            else
              resource_paths += Pod::Sandbox::PathList.new(Pathname(file_path)).glob('**/*')
            end
          end
        end
        resource_paths.uniq.each { |resource_path| stage_file(resource_path, stage_dir) }
      end

      def copy_resources(podspec, stage_dir)
        %w[preserve_paths resources].each { |attribute| transplant_tree_with_attribute(podspec, attribute, stage_dir) }
      end

      def transplant_tree_with_attribute(podspec, attribute, stage_dir)
        globs = Array(podspec.attributes_hash[attribute])
        globs.to_set.each { |glob| stage_glob(glob, stage_dir) }
      end

      def copy_license(podspec, stage_dir)
        return if podspec.license[:text]

        license_spec = podspec.license[:file]
        license_file = license_spec ? File.join(pod_dir, license_spec) : lookup_default_license_file
        return unless license_file

        stage_file(license_file, stage_dir)
      end

      def lookup_default_license_file
        podspec_dir_relative_glob(LICENSE_GLOB_PATTERNS).first
      end

      def stage_glob(glob, stage_dir)
        glob = File.join(glob, '**', '*') if File.directory?(File.join(pod_dir, glob))
        podspec_dir_relative_glob(glob).each { |file_path| stage_file(file_path, stage_dir) }
      end

      def podspec_dir_relative_glob(glob, options = {})
        Pod::Sandbox::PathList.new(Pathname(pod_dir)).glob(glob, options)
      end

      def stage_file(file_path, stage_dir)
        pathname = Pathname(file_path)

        relative_path_file = pathname.relative_path_from(Pathname(pod_dir)).dirname.to_path
        raise Informative, "Bad Relative path #{relative_path_file}" if relative_path_file.start_with?('..')

        staged_folder = File.join(stage_dir, relative_path_file)
        FileUtils.mkdir_p(staged_folder)
        staged_file_path = File.join(staged_folder, pathname.basename)
        raise Informative, "File #{staged_file_path} already exists." if File.exist?(staged_file_path)

        FileUtils.copy_file(pathname.to_path, staged_file_path)
      end

      def podspec_dir
        File.expand_path(File.dirname(podspec_to_pack))
      end

      def pod_dir
        @is_local ? podspec_dir : @sandbox_map.values.map { |sandbox| sandbox.pod_dir(@podspec.name)  }.first.to_path
      end

      def copy_headers(sandbox, target, stage_dir)
        header_path = File.join(sandbox.public_headers.root, target)
        cp_r_dereference(header_path, stage_dir)
      end

      def cp_r_dereference(src, dst)
        src_pn = Pathname.new(src)
        find_follow(src) do |path|
          relpath = Pathname.new(path).relative_path_from(src_pn).to_s
          dstpath = File.join(dst, relpath)

          if File.directory?(path) || (File.symlink?(path) && File.directory?(File.realpath(path)))
            FileUtils.mkdir_p(dstpath)
          else
            FileUtils.copy_file(path, dstpath)
          end
        end
      end

      def podfile_from_spec(platform, podspec, source_urls, linkage, local)
        Pod::Podfile.new do
          install!('cocoapods', warn_for_multiple_pod_sources: false)
          source_urls.each { |u| source(u) }
          use_frameworks!(linkage: linkage)
          platform(platform.name, platform.deployment_target)
          if local
            pod podspec.name, path: podspec.defined_in_file.to_s
          else
            pod podspec.name, podspec: podspec.defined_in_file.to_s
          end
          target CONCRETE_TARGET_NAME
        end
      end

      def podspec_to_pack
        @podspec_to_pack = begin
                            path = @podspec_path
                            if path =~ %r{https?://}
                              require 'cocoapods/open-uri'
                              output_path = podspecs_tmp_dir + File.basename(path)
                              output_path.dirname.mkpath
                              begin
                                OpenURI.open_uri(path) do |io|
                                  output_path.open('w') { |f| f << io.read }
                                end
                              rescue StandardError => e
                                raise Informative, "Downloading a podspec from `#{path}` failed: #{e}"
                              end
                              @is_local = false
                              output_path
                            elsif Pathname.new(path).directory?
                              raise Informative, "Podspec specified in `#{path}` is a directory."
                            else
                              pathname = Pathname.new(path)
                              raise Informative, "Unable to find a spec named `#{path}'." unless pathname.exist? && path.include?('.podspec')

                              @is_local = true
                              pathname
                            end
                          end
      end

      def podspecs_tmp_dir
        Pathname.new(Dir.tmpdir) + "CocoaPods-Bin/#{CocoapodsPack::VERSION}/Pack_podspec"
      end

      def type_from_platform(platform)
        return :simulator if platform == :ios
        return :simulator if platform == :watchos
        return :simulator if platform == :tvos

        nil
      end

      def available_platforms(podspec)
        return podspec.available_platforms if @skipped_platforms.empty?

        podspec.available_platforms.reject do |platform|
          @skipped_platforms.include? platform.string_name.gsub(/\s+/, '').downcase
        end
      end

      def shellout(command)
        output = `#{command}`
        [output, $CHILD_STATUS]
      end
    end
  end
end
