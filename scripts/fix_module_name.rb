require 'xcodeproj'

project_path = './Toplet.xcodeproj'
project = Xcodeproj::Project.open(project_path)

ui_test_target = project.targets.find { |t| t.name == 'TopletUITests' }

ui_test_target.build_configurations.each do |config|
  config.build_settings['PRODUCT_NAME'] = 'TopletUITests'
  config.build_settings['PRODUCT_MODULE_NAME'] = 'TopletUITests'
end

project.save
puts "Successfully updated build settings."
