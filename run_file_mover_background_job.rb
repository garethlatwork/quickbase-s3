
require_relative 'file_mover_job_launcher'
require 'yaml'

move_files = false
config_file = "config.yml"

if ARGV[0]
  ARGV.each{|arg| 
    if arg == "-move"
      move_files = true
    else
      config_file = arg
    end    
   } 
end

config = YAML.load_file(config_file)
if config["use_environmment_variables"] and config["use_environmment_variables"] == "true"
  config.each{|k,v| config[k] = ENV[k.to_s] if ENV[k.to_s]}
end

fmjl = FileMoverJobLauncher.new(config,move_files)
fmjl.launch_file_mover_job

puts "File Mover background job launched successfully."

