require "rake/testtask"

Rake::TestTask.new(:test) do |t|
  t.libs << "test" << "lib"
  t.test_files = FileList["test/**/*_test.rb"].exclude("test/live/**")
end

Rake::TestTask.new("test:live") do |t|
  t.libs << "test" << "lib"
  t.pattern = "test/live/*_test.rb"
end


task default: :test
