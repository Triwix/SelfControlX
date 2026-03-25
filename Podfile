source 'https://github.com/CocoaPods/Specs.git'

minVersion = '10.13'

platform :osx, minVersion

# cocoapods-prune-localizations doesn't appear to auto-detect pods properly, so using a manual list
supported_locales = ['Base', 'da', 'de', 'en', 'es', 'fr', 'it', 'ja', 'ko', 'nl', 'pt-BR', 'sv', 'tr', 'zh-Hans']
plugin 'cocoapods-prune-localizations', { :localizations => supported_locales }

def ensure_writable(path)
    return unless File.exist?(path)
    return if File.writable?(path)

    File.chmod(0o644, path)
end

def apply_selfcontrolx_patch(path, marker, description)
    unless File.exist?(path)
        puts "[SelfControlX][patch] #{description}: skipped (missing file)"
        return
    end

    ensure_writable(path)
    contents = File.read(path)

    if contents.include?(marker)
        puts "[SelfControlX][patch] #{description}: already applied"
        return
    end

    updated = yield(contents)
    if updated.nil?
        puts "[SelfControlX][patch] #{description}: no changes required"
        return
    end

    updated = "#{marker}\n#{updated}" unless updated.include?(marker)
    if updated == contents
        puts "[SelfControlX][patch] #{description}: no changes required"
        return
    end

    File.write(path, updated)
    puts "[SelfControlX][patch] #{description}: applied"
end

def patch_maspreferences_scripts(script_paths, built_nib, source_xib)
    script_paths.each do |script_path|
        next unless File.exist?(script_path)

        ensure_writable(script_path)
        script_contents = File.read(script_path)
        next unless script_contents.include?(built_nib)

        script_contents.gsub!(built_nib, source_xib)
        File.write(script_path, script_contents)
        puts "[SelfControlX][patch] MASPreferences resources script updated: #{script_path}"
    end
end

target "SelfControl" do
    use_frameworks! :linkage => :static
    pod 'MASPreferences', '~> 1.1.4'
    pod 'TransformerKit', '~> 1.1.1'
    pod 'FormatterKit/TimeIntervalFormatter', '~> 1.8.0'
    pod 'LetsMove', '~> 1.24'
    pod 'Sentry', :git => 'https://github.com/getsentry/sentry-cocoa.git', :tag => '7.3.0'

    # Add test target
    target 'SelfControlTests' do
        inherit! :complete
    end
end

target "SelfControl Killer" do
    use_frameworks! :linkage => :static
    pod 'Sentry', :git => 'https://github.com/getsentry/sentry-cocoa.git', :tag => '7.3.0'
end

# we can't use_frameworks on these because they're command-line tools
# Sentry says we need use_frameworks, but they seem to work OK anyway?
target "SCKillerHelper" do
    pod 'Sentry', :git => 'https://github.com/getsentry/sentry-cocoa.git', :tag => '7.3.0'
end
target "selfcontrol-cli" do
    pod 'Sentry', :git => 'https://github.com/getsentry/sentry-cocoa.git', :tag => '7.3.0'
end
target "org.eyebeam.selfcontrold" do
    pod 'Sentry', :git => 'https://github.com/getsentry/sentry-cocoa.git', :tag => '7.3.0'
end

post_install do |pi|
    puts '[SelfControlX] Running post_install configuration'

    # Normalize pod build output so .xcodeproj and .xcworkspace builds resolve pod products
    # from the same deterministic path.
    pi.pods_project.build_configurations.each do |bc|
        bc.build_settings['SYMROOT'] = '$(BUILD_DIR)'
        deployment_target = bc.build_settings['MACOSX_DEPLOYMENT_TARGET']
        if deployment_target.nil? || Gem::Version.new(deployment_target) < Gem::Version.new(minVersion)
            bc.build_settings['MACOSX_DEPLOYMENT_TARGET'] = minVersion
        end
    end

    pi.pods_project.targets.each do |t|
        t.build_configurations.each do |bc|
            deployment_target = bc.build_settings['MACOSX_DEPLOYMENT_TARGET']
            if deployment_target.nil? || Gem::Version.new(deployment_target) < Gem::Version.new(minVersion)
                bc.build_settings['MACOSX_DEPLOYMENT_TARGET'] = minVersion
            end
            bc.build_settings['SYMROOT'] = '$(BUILD_DIR)'
        end
    end

    # Newer Xcode toolchains require <exception> for std::set_terminate declarations.
    sentry_cpp_monitor = File.join(__dir__, 'Pods', 'Sentry', 'Sources', 'SentryCrash', 'Recording', 'Monitors', 'SentryCrashMonitor_CPPException.cpp')
    apply_selfcontrolx_patch(
        sentry_cpp_monitor,
        '// SELFCONTROLX_PATCH_SENTRY_CPP_EXCEPTION',
        'Sentry C++ terminate handler include'
    ) do |contents|
        updated = contents.dup
        unless updated.include?('#include <exception>')
            updated.sub!('#include <typeinfo>', "#include <exception>\n#include <typeinfo>")
        end
        updated
    end

    # Newer SDKs require explicit inclusion of ucontext64 typedef before use.
    sentry_machine_context = File.join(__dir__, 'Pods', 'Sentry', 'Sources', 'SentryCrash', 'Recording', 'Tools', 'SentryCrashMachineContext.c')
    apply_selfcontrolx_patch(
        sentry_machine_context,
        '/* SELFCONTROLX_PATCH_SENTRY_UCONTEXT64 */',
        'Sentry machine context ucontext64 include'
    ) do |contents|
        updated = contents.dup
        ucontext_include = "/* SELFCONTROLX_PATCH_SENTRY_UCONTEXT64 */\n#if defined(__arm64__) && __has_include(<sys/_types/_ucontext64.h>)\n#include <sys/_types/_ucontext64.h>\n#endif\n"
        unless updated.include?('sys/_types/_ucontext64.h')
            updated.sub!('#include <mach/mach.h>', "#include <mach/mach.h>\n#{ucontext_include}")
        end
        updated
    end

    # TransformerKit relies on old Darwin submodules removed by newer SDKs.
    transformerkit_value_transformer_impl = File.join(__dir__, 'Pods', 'TransformerKit', 'Sources', 'NSValueTransformer+TransformerKit.m')
    apply_selfcontrolx_patch(
        transformerkit_value_transformer_impl,
        '// SELFCONTROLX_PATCH_TRANSFORMERKIT_AVAILABILITY_IMPL',
        'TransformerKit NSValueTransformer+TransformerKit Availability import'
    ) do |contents|
        updated = contents.dup
        updated.sub!('@import Darwin.Availability;', '#import <Availability.h>')
        updated
    end

    transformerkit_value_transformer_name_h = File.join(__dir__, 'Pods', 'TransformerKit', 'Sources', 'NSValueTransformerName.h')
    apply_selfcontrolx_patch(
        transformerkit_value_transformer_name_h,
        '// SELFCONTROLX_PATCH_TRANSFORMERKIT_AVAILABILITY_HEADER',
        'TransformerKit NSValueTransformerName Availability import'
    ) do |contents|
        updated = contents.dup
        updated.sub!('@import Darwin.Availability;', '#import <Availability.h>')
        updated
    end

    transformerkit_date_transformers = File.join(__dir__, 'Pods', 'TransformerKit', 'Sources', 'TTTDateTransformers.m')
    apply_selfcontrolx_patch(
        transformerkit_date_transformers,
        '/* SELFCONTROLX_PATCH_TRANSFORMERKIT_DATE */',
        'TransformerKit date parser SDK compatibility'
    ) do |contents|
        updated = contents.dup
        updated.sub!('@import Darwin.C.time;', '#include <time.h>')
        updated.sub!('@import Darwin.C.xlocale;', '#include <locale.h>')
        updated.gsub!('strptime_l(destination, "%FT%T%z", &time, NULL);', 'strptime(destination, "%FT%T%z", &time);')
        updated.gsub!('strptime_l(source, format, &time, NULL);', 'strptime(source, format, &time);')
        updated
    end

    # MASPreferences copy-resources scripts can reference a built nib path that is not
    # always present in modern static framework builds. Use the source xib path instead.
    maspreferences_built_nib = '${BUILT_PRODUCTS_DIR}/MASPreferences/MASPreferences.framework/en.lproj/MASPreferencesWindow.nib'
    maspreferences_source_xib = '${PODS_ROOT}/MASPreferences/Framework/en.lproj/MASPreferencesWindow.xib'

    resources_scripts = Dir.glob(File.join(__dir__, 'Pods', 'Target Support Files', '**', '*-resources.sh'))
    patch_maspreferences_scripts(resources_scripts, maspreferences_built_nib, maspreferences_source_xib)

    # Keep the user project script-phase input paths in sync with the rewritten resource path.
    user_project_pbxproj = File.join(__dir__, 'SelfControl.xcodeproj', 'project.pbxproj')
    if File.exist?(user_project_pbxproj)
        ensure_writable(user_project_pbxproj)
        project_contents = File.read(user_project_pbxproj)
        if project_contents.include?(maspreferences_built_nib)
            project_contents.gsub!(maspreferences_built_nib, maspreferences_source_xib)
            File.write(user_project_pbxproj, project_contents)
            puts '[SelfControlX][patch] Updated user project MASPreferences input path'
        else
            puts '[SelfControlX][patch] User project MASPreferences input path already updated'
        end
    end
end
