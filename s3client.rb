
require 'right_aws'
require 'yaml'

class Net::HTTP
  alias_method :old_initialize, :initialize
  def initialize(*args)
    old_initialize(*args)
    @verify_mode = OpenSSL::SSL::VERIFY_NONE
    @use_ssl=true
  end
end

BUCKET_NAME = "quickbase_files"

class S3Client

  attr_reader :bucket_name

  def initialize(params=nil)
    if params
      @config = params.dup 
    elsif File.exist?("config.yml")  
      @config = YAML.load_file("config.yml")
    end
    @client = RightAws::S3Interface.new(@config["aws_access_key"],@config["aws_secret_key"])
    @bucket_name = @config["bucket_name"] || BUCKET_NAME
  end  

  def bucket_exists?
    exists = false
    begin
      exists = @client.list_bucket(@bucket_name.dup)
    rescue
    end
    exists
  end

  def create_bucket
    @client.create_bucket(@bucket_name.dup)
    bucket_exists?
  end  

  def list_buckets
    puts "link:\n #{@client.list_bucket_link(@bucket_name.dup)}\n\n"
    @client.incrementally_list_bucket(@bucket_name.dup) { |c| p c }
  end  

  def delete_folder(key)
    response = nil
    raise "key is missing" unless key
    begin
       response = @client.delete_folder(@bucket_name, key)
    rescue StandardError => error
       response = error
    end
    response
  end  

  def key_exists?(bucket_instance,string)
    exists = false
    begin
      key = RightAws::S3::Key.create(bucket_instance,string) 
      exists = key.exists?
    rescue StandardError => error
      puts error
    end
    exists
  end

  def keys(prefix=nil)
    response = nil
    begin
      response = @client.list_bucket(@bucket_name.dup, { 'prefix' => prefix } )
    rescue StandardError => error
      puts error
    end
    response
  end

  def delete_key(key)
    response = nil
    raise "key is missing" unless key
    begin
       response = @client.delete(@bucket_name.dup, key)
    rescue StandardError => error
       response = error
    end
    response
  end  

  def upload_file(file_name,key=nil)
    response = nil
    begin
       key ||= file_name
       response = @client.store_object({:bucket => @bucket_name.dup, :key => key,  :md5 => "a507841b1bc8115094b00bbe8c1b2954", :data => File.open(file_name,"rb") })
    rescue StandardError => error
       response = error
    end
    response
  end  

  def download_file(file_name,key=nil)
    response = nil
    begin
       key ||= file_name
       response = @client.retrieve_object({:bucket => @bucket_name.dup, :key => key })
    rescue StandardError => error
       response = error
    end
    response
  end  
  
end
