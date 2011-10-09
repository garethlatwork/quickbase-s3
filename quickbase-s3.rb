
require 'sinatra'
require 'rack/ssl-enforcer'
require 'rack/flash'
require 'yaml'
require_relative 'file_mover_job_launcher'
require_relative 's3client'

ENV['RACK_ENV'] ||= 'development'

configure do
  if settings.environment == :production
    use Rack::SslEnforcer
  end
end

not_found do
  "<h1>Invalid request</h1>"
end

get '/' do
  "<h1>Invalid request</h1>"
end

get '/download_file' do
  download_file(params)
end

post '/download_file' do
  download_file(params)
end

post '/copy_files_to_s3' do
  launch_file_mover_job(params,false)
end

post '/move_files_to_s3' do
  launch_file_mover_job(params,true)
end

private

def download_file(params)
  ret = "<h2>Error downloading file from S3.</h2>"
  config = get_config(params)
  s3c =  S3Client.new(config)
  response = s3c.download_file(config[:key])
  unless response.is_a?(RightAws::AwsError)
    key_parts = config[:key].split(/\//)
    filename = key_parts[-1]
    attachment(filename)
    content_type(Rack::Mime::MIME_TYPES[File.extname(filename)] || "text/html" )
    ret = response[:object]
  end
  ret
  rescue StandardError => exception
  msg = "Error downloading file: #{exception}"
  puts msg
  puts exception.backtrace
  msg
end

def launch_file_mover_job(params,move_files)
  config = get_config(params)
  fmjl = FileMoverJobLauncher.new(config,move_files)
  fmjl.launch_file_mover_job
  "Background job launched successfully."
  rescue StandardError => exception
  msg = "Error launching background job: #{exception}"
  puts msg
  puts exception.backtrace
  msg
end

def get_config(params)
  params.keys{|key|params[key.to_s] = params[key]}
  params.reject!{|k,v|(v and v.length == 0)}
  config = YAML.load_file("config.yml")
  if config["use_environmment_variables"] and config["use_environmment_variables"] == "true"
    config.each{|k,v| config[k] = ENV[k.to_s] if ENV[k.to_s]}
  end
  config.merge!(params)
  config
end
