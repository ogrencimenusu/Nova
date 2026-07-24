require 'xcodeproj'
project_path = 'Nova.xcodeproj'
project = Xcodeproj::Project.open(project_path)

project.targets.each do |target|
  puts "Target: #{target.name}"
  target.resources_build_phase.files.each do |file|
    puts "  - #{file.file_ref.path}" if file.file_ref && file.file_ref.path
  end
end
