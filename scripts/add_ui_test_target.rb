require 'xcodeproj'

project_path = './Toplet.xcodeproj'
project = Xcodeproj::Project.open(project_path)

if project.targets.any? { |t| t.name == 'TopletUITests' }
  puts "Target TopletUITests already exists."
  exit 0
end

app_target = project.targets.find { |t| t.name == 'Toplet' }

ui_test_target = project.new_target(:ui_test_bundle, 'TopletUITests', :osx)

test_group = project.main_group.find_subpath(File.join('TopletUITests'), true)
test_group.set_source_tree('<group>')
test_group.set_path('TopletUITests')

file_ref = test_group.new_reference('TopletUITests.swift')
info_plist_ref = test_group.new_reference('Info.plist')

ui_test_target.add_file_references([file_ref])

ui_test_target.build_configurations.each do |config|
  config.build_settings['TEST_TARGET_NAME'] = 'Toplet'
  config.build_settings['PRODUCT_BUNDLE_IDENTIFIER'] = 'com.atoll.TopletUITests'
  config.build_settings['INFOPLIST_FILE'] = 'TopletUITests/Info.plist'
  config.build_settings['SWIFT_VERSION'] = '5.0'
  config.build_settings['MACOSX_DEPLOYMENT_TARGET'] = '14.0'
  # Important for UI testing bundle to link XCTest correctly
  config.build_settings['FRAMEWORK_SEARCH_PATHS'] = ['$(inherited)', '$(PLATFORM_DIR)/Developer/Library/Frameworks']
  config.build_settings['LD_RUNPATH_SEARCH_PATHS'] = ['$(inherited)', '@executable_path/../Frameworks', '@loader_path/../Frameworks']
end

project.save
puts "Successfully added TopletUITests target to the project."
