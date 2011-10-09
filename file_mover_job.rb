
require 'simple_worker'
require_relative 'file_mover'

class FileMoverJob < SimpleWorker::Base

  attr_accessor :params

  merge_gem "quickbase_client"
  merge_gem "right_http_connection"
  merge_gem "right_aws"
  merge_gem "i18n"
  merge_gem "gmail_sender"
  merge "file_mover"
  merge "s3client"

  def run
    fm = FileMover.new(params)
    fm.copy_or_move_files_to_s3
  end

end

