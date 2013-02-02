module Pod
  class Installer

    # Controller class responsible of installing the activated specifications
    # of a single Pod.
    #
    # @note This class needs to consider all the activated specs of a Pod.
    #
    class PodSourceInstaller

      # TODO: local option specs.
      # TODO: add tests for multi platform / subspecs issues.

      # @return [Sandbox]
      #
      attr_reader :sandbox

      # @return [Hash{Symbol=>Array}] The specifications that need to be
      #         installed grouped by platform.
      #
      attr_reader :specs_by_platform

      # @param [Sandbox] sandbox @see sandbox
      # @param [Hash{Symbol=>Array}] specs_by_platform @see specs_by_platform
      #
      def initialize(sandbox, specs_by_platform)
        @sandbox = sandbox
        @specs_by_platform = specs_by_platform

        @clean           = true
        @generate_docs   = false
        @install_docs    = false
        @agressive_cache = false
      end

      #-----------------------------------------------------------------------#

      extend DependencyInjection

      dependency :downloader_class, Downloader
      dependency :docs_generator_class, Generator::Documentation

      #-----------------------------------------------------------------------#

      public

      # @!group Configuration

      # @return [Pathname] the path of the source of the Pod if using the
      #         `:local` option.
      #
      attr_accessor :local_path

      # @return [Bool] whether the file not used by CocoaPods should be
      #         removed.
      #
      attr_accessor :clean
      alias_method  :clean?, :clean

      # @return [Bool] whether the downloader should always check against the
      #         remote if issues might be generated (mostly useful to speed up
      #         testing).
      #
      # @note   This might be removed in future.
      #
      attr_accessor :agressive_cache
      alias_method  :agressive_cache?, :agressive_cache

      # @return [Bool] whether the documentation should be generated for the
      #         Pod.
      #
      attr_accessor :generate_docs
      alias_method  :generate_docs?, :generate_docs

      # @return [Bool] whether the generated documentation should be installed
      #         in Xcode.
      #
      attr_accessor :install_docs
      alias_method  :install_docs?, :install_docs

      #-----------------------------------------------------------------------#

      public

      # @!group Installation

      # Creates the target in the Pods project and the relative support files.
      #
      # @return [void]
      #
      def install!
        download_source     unless predownloaded? || local?
        generate_docs       if generate_docs?
        clean_installation  if clean? && !local?
        link_headers
      end

      # @return [Hash]
      #
      attr_reader :specific_source

      #-----------------------------------------------------------------------#

      private

      # @!group Installation Steps

      # Downloads the source of the Pod. It also stores the specific options
      # needed to recreate the same exact installation if needed in
      # `#specific_source`.
      #
      # @return [void]
      #
      def download_source
        root.rmtree if root.exist?
        if root_spec.version.head?
          downloader.download_head
          @specific_source = downloader.checkout_options
        else
          downloader.download
          unless downloader.options_specific?
            @specific_source = downloader.checkout_options
          end
        end
      end

      # Generates the documentation for the Pod.
      #
      # @return [void]
      #
      def generate_docs
        if @cleaned
          raise Informative, "Attempt to generate the documentation from a cleaned Pod."
        end

        if documentation_generator.already_installed?
          UI.section " > Using existing documentation"
        else
          UI.section " > Installing documentation" do
            documentation_generator.generate(install_docs?)
          end
        end
      end

      # Removes all the files not needed for the installation according to the
      # specs by platform.
      #
      # @return [void]
      #
      def clean_installation
        clean_paths.each { |path| FileUtils.rm_rf(path) }
        @cleaned = true
      end

      # Creates the link to the headers of the Pod in the sandbox.
      #
      # @return [void]
      #
      def link_headers
        headers_sandbox = Pathname.new(root_spec.name)
        sandbox.build_headers.add_search_path(headers_sandbox)
        sandbox.public_headers.add_search_path(headers_sandbox)

        file_accessors.each do |file_accessor|
          consumer = file_accessor.spec_consumer
          header_mappings(headers_sandbox, consumer, file_accessor.headers).each do |namespaced_path, files|
            sandbox.build_headers.add_files(namespaced_path, files)
          end

          header_mappings(headers_sandbox, consumer, file_accessor.public_headers).each do |namespaced_path, files|
            sandbox.public_headers.add_files(namespaced_path, files)
          end
        end
      end

      #-----------------------------------------------------------------------#

      public

      # @!group Dependencies

      # @return [String] The directory where CocoaPods caches the downloads.
      #
      CACHE_ROOT = "~/Library/Caches/CocoaPods"

      # @return [Fixnum] The maximum size for the cache expressed in Mb.
      #
      MAX_CACHE_SIZE = 500

      # @return [Downloader] The downloader to use for the retrieving the
      #         source.
      #
      def downloader
        return @downloader if @downloader
        @downloader = self.class.downloader_class.for_target(root, root_spec.source.dup)
        @downloader.cache_root = CACHE_ROOT
        @downloader.max_cache_size = MAX_CACHE_SIZE
        @downloader.agressive_cache = agressive_cache?
        @downloader
      end

      # @return [Generator::Documentation] The documentation generator to use
      #         for generating the documentation.
      #
      def documentation_generator
        @documentation_generator ||= self.class.docs_generator_class.new(sandbox, root_spec, path_list)
      end

      #-----------------------------------------------------------------------#

      private

      # @!group Convenience methods.

      # @return [Array<Specifications>] the specification of the Pod used in
      #         this installation.
      #
      def specs
        specs_by_platform.values.flatten
      end

      # @return [Specification] the root specification of the Pod.
      #
      def root_spec
        specs.first.root
      end

      # @return [Pathname] the folder where the source of the Pod is located.
      #
      def root
        local? ? local_path : sandbox.pod_dir(root_spec.name)
      end

      # @return [Boolean] whether the source has been pre downloaded in the
      #         resolution process to retrieve its podspec.
      #
      def predownloaded?
        sandbox.predownloaded_pods.include?(root_spec.name)
      end

      # @return [Boolean] whether the pod uses the local option and thus
      #         CocoaPods should not interfere with the files of the user.
      #
      def local?
        !local_path.nil?
      end

      #-----------------------------------------------------------------------#

      private

      # @!group Private helpers

      # @return [Array<Sandbox::FileAccessor>] the file accessors for all the
      #         specifications on their respective platform.
      #
      def file_accessors
        return @file_accessors if @file_accessors
        @file_accessors = []
        specs_by_platform.each do |platform, specs|
          specs.each do |spec|
            @file_accessors << Sandbox::FileAccessor.new(path_list, spec.consumer(platform))
          end
        end
        @file_accessors
      end

      # @return [Sandbox::PathList] The path list for this Pod.
      #
      def path_list
        @path_list ||= Sandbox::PathList.new(root)
      end

      # Finds the absolute paths, including hidden ones, of the files
      # that are not used by the pod and thus can be safely deleted.
      #
      # @note   Implementation detail: Don't use `Dir#glob` as there is an
      #         unexplained issue (#568, #572 and #602).
      #
      # @return [Array<Strings>] The paths that can be deleted.
      #
      def clean_paths
        cached_used = used_files
        glob_options = File::FNM_DOTMATCH | File::FNM_CASEFOLD
        files = Pathname.glob(root + "**/*", glob_options).map(&:to_s)

        files.reject! do |candidate|
          candidate.end_with?('.', '..') || cached_used.any? do |path|
            path.include?(candidate) || candidate.include?(path)
          end
        end
        files
      end

      # @return [Array<String>] The absolute path of all the files used by the
      #         specifications (according to their platform) of this Pod.
      #
      def used_files
        files = [
          file_accessors.map(&:source_files),
          file_accessors.map(&:resources),
          file_accessors.map(&:preserve_paths),
          file_accessors.map(&:prefix_header),
          file_accessors.map(&:readme),
          file_accessors.map(&:license),
        ]
        files.compact!
        files.flatten!
        files.map!{ |path| path.to_s }
        files
      end


      # Computes the destination sub-directory in the sandbox
      #
      # @param  []
      #
      # @return [Hash{Pathname => Array<Pathname>}] A hash containing the
      #         headers folders as the keys and the absolute paths of the
      #         header files as the values.
      #
      # TODO    This is being overridden in the RestKit 0.9.4 spec and that
      #         override should be fixed.
      #
      def header_mappings(headers_sandbox, consumer, headers)
        dir = headers_sandbox
        dir = base_dir + consumer.header_dir if consumer.header_dir

        mappings = {}
        headers.each do |header|
          relative_path = header.relative_path_from(root)
          sub_dir = dir
          if consumer.header_mappings_dir
            sub_dir = sub_dir + header.relative_path_from(consumer.header_mappings_dir).dirname
          end
          mappings[sub_dir] ||= []
          mappings[sub_dir] << header
        end
        mappings
      end

      #-----------------------------------------------------------------------#

    end
  end
end
