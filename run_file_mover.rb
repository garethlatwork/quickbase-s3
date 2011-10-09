
require_relative 'file_mover'
require 'yaml'

config = YAML.load_file(ARGV[0] || "config.yml")
if config["use_environmment_variables"] and config["use_environmment_variables"] == "true"
  config.each{|k,v| config[k] = ENV[k.to_s] if ENV[k.to_s]}
end
fm = FileMover.new(config)
fm.copy_or_move_files_to_s3
