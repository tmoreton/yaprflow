#!/usr/bin/env ruby
# frozen_string_literal: true

# Adds the yaprflow-iOS App target and the yaprflow-iOS-Keyboard extension
# target to yaprflow.xcodeproj. Idempotent — re-running rebuilds both targets
# cleanly without duplicating references.

require "rubygems"
gem "xcodeproj", "= 1.27.0"
require "xcodeproj"

ROOT         = File.expand_path("..", __dir__)
PROJECT_PATH = File.join(ROOT, "yaprflow.xcodeproj")

APP_TARGET   = "yaprflow-iOS"
APP_BUNDLE   = "com.tmoreton.yaprflow.ios"
APP_DIR      = "yaprflow-iOS"

KBD_TARGET   = "yaprflow-iOS-Keyboard"
KBD_BUNDLE   = "com.tmoreton.yaprflow.ios.keyboard"
KBD_DIR      = "yaprflow-iOS-Keyboard"

DEPLOYMENT   = "17.0"
APP_GROUP    = "group.com.tmoreton.yaprflow"
MODELS_DIR   = "Models"

# Source files keyed by target. The Shared/ files are added to BOTH targets so
# the keyboard extension can use AppGroup helpers and the chunk format without
# needing a separate framework.
APP_SOURCES = %w[
  YaprflowApp.swift
  ContentView.swift
  TranscriptionEngine.swift
  AudioCapture.swift
  HistoryStore.swift
].freeze

SHARED_SOURCES = %w[
  Shared/AppGroup.swift
].freeze

KBD_SOURCES = %w[
  KeyboardViewController.swift
  KeyboardView.swift
  KeyboardSession.swift
  KeyboardLayout.swift
].freeze

APP_INFO_PLIST   = "yaprflow-iOS/Info.plist"
APP_ENTITLEMENTS = "yaprflow-iOS/yaprflow-iOS.entitlements"
KBD_INFO_PLIST   = "yaprflow-iOS-Keyboard/Info.plist"
KBD_ENTITLEMENTS = "yaprflow-iOS-Keyboard/yaprflow-iOS-Keyboard.entitlements"

ASSET_CATALOGS = %w[Assets.xcassets].freeze

project = Xcodeproj::Project.open(PROJECT_PATH)

# ----- helpers ---------------------------------------------------------------

def remove_target(project, name)
  existing = project.targets.find { |t| t.name == name }
  return unless existing
  project.targets.each do |t|
    t.dependencies.delete_if { |d| d.target == existing }
  end
  existing.build_configuration_list.build_configurations.each(&:remove_from_project)
  existing.build_configuration_list.remove_from_project
  existing.build_phases.each do |phase|
    phase.files.each(&:remove_from_project)
    phase.remove_from_project
  end
  existing.remove_from_project
end

def remove_top_group(project, name)
  group = project.main_group.children.find do |c|
    c.is_a?(Xcodeproj::Project::Object::PBXGroup) && c.name == name
  end
  group&.remove_from_project
end

# ----- clear any prior state -------------------------------------------------

%w[yaprflow-iOS yaprflow-iOS-Keyboard].each { |t| remove_target(project, t) }
remove_top_group(project, APP_DIR)
remove_top_group(project, KBD_DIR)

# ----- create iOS app target -------------------------------------------------

app_target = project.new_target(:application, APP_TARGET, :ios, DEPLOYMENT, nil, :swift)
app_group = project.main_group.new_group(APP_DIR, APP_DIR)

APP_SOURCES.each do |fname|
  ref = app_group.new_reference(fname)
  app_target.add_file_references([ref])
end

# Shared sources: add to app target, remember the refs so we can re-use them
# on the keyboard target without duplicating file references.
shared_group = app_group.new_group("Shared", "Shared")
shared_refs = SHARED_SOURCES.map do |fname|
  bare = File.basename(fname)
  ref = shared_group.new_reference(bare)
  app_target.add_file_references([ref])
  ref
end

ASSET_CATALOGS.each do |cat|
  ref = app_group.new_reference(cat)
  app_target.resources_build_phase.add_file_reference(ref, true)
end

# Info.plist + entitlements: just file references, not in any build phase.
app_group.new_reference("Info.plist")
app_group.new_reference("yaprflow-iOS.entitlements")

# Models folder (shared with the Mac target via its existing membership).
models_ref = project.main_group.children.find { |c| c.respond_to?(:path) && c.path == MODELS_DIR }
unless models_ref
  models_ref = project.main_group.new_reference(MODELS_DIR)
  models_ref.last_known_file_type = "folder"
end
app_target.resources_build_phase.add_file_reference(models_ref, true)

# iOS app build settings
app_target.build_configurations.each do |config|
  s = config.build_settings
  s["PRODUCT_BUNDLE_IDENTIFIER"] = APP_BUNDLE
  s["PRODUCT_NAME"] = "$(TARGET_NAME)"
  s["INFOPLIST_FILE"] = APP_INFO_PLIST
  s["CODE_SIGN_ENTITLEMENTS"] = APP_ENTITLEMENTS
  s["IPHONEOS_DEPLOYMENT_TARGET"] = DEPLOYMENT
  s["TARGETED_DEVICE_FAMILY"] = "1,2"
  s["SDKROOT"] = "iphoneos"
  s["SUPPORTED_PLATFORMS"] = "iphoneos iphonesimulator"
  s["SWIFT_VERSION"] = "5.0"
  s["GENERATE_INFOPLIST_FILE"] = "NO"
  s["ENABLE_PREVIEWS"] = "YES"
  s["CURRENT_PROJECT_VERSION"] = "1"
  s["MARKETING_VERSION"] = "1.0.0"
  s["ASSETCATALOG_COMPILER_APPICON_NAME"] = "AppIcon"
  s["ASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME"] = "AccentColor"
  s["CODE_SIGN_STYLE"] = "Automatic"
  s["SUPPORTS_MACCATALYST"] = "NO"
  s["SUPPORTS_MAC_DESIGNED_FOR_IPHONE_IPAD"] = "NO"
  s["LD_RUNPATH_SEARCH_PATHS"] = ["$(inherited)", "@executable_path/Frameworks"]
  s["DEVELOPMENT_TEAM"] = ""
end

# FluidAudio package on the iOS app target (keyboard does NOT link it).
fluid_pkg = project.root_object.package_references.find do |ref|
  ref.respond_to?(:repositoryURL) && ref.repositoryURL.to_s.include?("FluidAudio")
end
abort "FluidAudio package reference not found in project" unless fluid_pkg

fluid_dep = project.new(Xcodeproj::Project::Object::XCSwiftPackageProductDependency)
fluid_dep.package = fluid_pkg
fluid_dep.product_name = "FluidAudio"
app_target.package_product_dependencies << fluid_dep

fw_bf = project.new(Xcodeproj::Project::Object::PBXBuildFile)
fw_bf.product_ref = fluid_dep
app_target.frameworks_build_phase.files << fw_bf

# ----- create keyboard extension target --------------------------------------

kbd_target = project.new_target(:app_extension, KBD_TARGET, :ios, DEPLOYMENT, nil, :swift)
kbd_group = project.main_group.new_group(KBD_DIR, KBD_DIR)

KBD_SOURCES.each do |fname|
  ref = kbd_group.new_reference(fname)
  kbd_target.add_file_references([ref])
end

# Share AppGroup.swift + AudioChunkFile.swift with the keyboard target
# (same file references, second target membership).
shared_refs.each do |ref|
  kbd_target.add_file_references([ref])
end

# Info.plist + entitlements references
kbd_group.new_reference("Info.plist")
kbd_group.new_reference("yaprflow-iOS-Keyboard.entitlements")

kbd_target.build_configurations.each do |config|
  s = config.build_settings
  s["PRODUCT_BUNDLE_IDENTIFIER"] = KBD_BUNDLE
  s["PRODUCT_NAME"] = "$(TARGET_NAME)"
  s["INFOPLIST_FILE"] = KBD_INFO_PLIST
  s["CODE_SIGN_ENTITLEMENTS"] = KBD_ENTITLEMENTS
  s["IPHONEOS_DEPLOYMENT_TARGET"] = DEPLOYMENT
  s["TARGETED_DEVICE_FAMILY"] = "1,2"
  s["SDKROOT"] = "iphoneos"
  s["SUPPORTED_PLATFORMS"] = "iphoneos iphonesimulator"
  s["SWIFT_VERSION"] = "5.0"
  s["GENERATE_INFOPLIST_FILE"] = "NO"
  s["CURRENT_PROJECT_VERSION"] = "1"
  s["MARKETING_VERSION"] = "1.0.0"
  s["CODE_SIGN_STYLE"] = "Automatic"
  s["DEVELOPMENT_TEAM"] = ""
  s["LD_RUNPATH_SEARCH_PATHS"] = ["$(inherited)", "@executable_path/Frameworks", "@executable_path/../../Frameworks"]
  s["SKIP_INSTALL"] = "YES"
  s["APPLICATION_EXTENSION_API_ONLY"] = "YES"
end

# ----- embed keyboard extension into app -------------------------------------

# Make the app depend on the keyboard so it builds first.
app_target.add_dependency(kbd_target)

# Create an "Embed App Extensions" copy-files phase on the app, with dst=plugins.
embed_phase = project.new(Xcodeproj::Project::Object::PBXCopyFilesBuildPhase)
embed_phase.name = "Embed App Extensions"
embed_phase.symbol_dst_subfolder_spec = :plug_ins # 13
embed_phase.run_only_for_deployment_postprocessing = "0"
app_target.build_phases << embed_phase

# Add the keyboard's product (.appex) as a build file in that phase.
kbd_product = kbd_target.product_reference
embed_bf = project.new(Xcodeproj::Project::Object::PBXBuildFile)
embed_bf.file_ref = kbd_product
embed_bf.settings = { "ATTRIBUTES" => ["RemoveHeadersOnCopy"] }
embed_phase.files << embed_bf

# ----- schemes ---------------------------------------------------------------

app_scheme = Xcodeproj::XCScheme.new
app_scheme.add_build_target(app_target)
app_scheme.add_build_target(kbd_target, false) # build-only, no test/run
app_scheme.set_launch_target(app_target)
app_scheme.save_as(PROJECT_PATH, APP_TARGET, true)

kbd_scheme = Xcodeproj::XCScheme.new
kbd_scheme.add_build_target(kbd_target)
kbd_scheme.save_as(PROJECT_PATH, KBD_TARGET, true)

project.save

puts "OK — added targets:"
puts "  - #{APP_TARGET} (#{APP_BUNDLE})"
puts "  - #{KBD_TARGET} (#{KBD_BUNDLE})   embedded as PlugIn"
